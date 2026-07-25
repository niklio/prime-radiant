import Foundation
import Observation
import PrimeRadiantCore

/// State for one open scenario: the live tree, client-computed analytics, the
/// selection, chat streaming, and marking. All math comes from PrimeRadiantCore
/// (handoff §4: optimal is computed, not vibed) — nothing here re-derives it.
@MainActor
@Observable
final class ScenarioStore {

    private(set) var scenario: Scenario
    private(set) var analytics: TreeAnalytics

    var selectedNodeId: String?
    var isDistributionExpanded = false

    // Chat surface state.
    var isChatPresented = false
    var focusedNodeId: String?
    private(set) var streamingSay = ""
    private(set) var isStreaming = false
    /// Set while a fresh patch animates: drives "◈ the futures reorganize…" + chip.
    private(set) var reorganizing = false

    /// Terminal node awaiting the resolve flow (hold on a terminal, §2.3).
    var pendingResolveNodeId: String?

    var lastError: String?

    // Quiet states (pivot §3) — no dialogs, one line in the composer slot.

    /// Box beyond reach: canvas renders read-only, composer + marking disable.
    var isReadOnly = false
    /// Usage window exhausted: composing pauses until the cycle renews.
    /// Set by a failed turn or by the gateway's health/budget report.
    private(set) var resting = false

    /// The gateway health gate reports budget "resting"/ok (server/README).
    func setResting(_ value: Bool) {
        resting = value
    }

    /// The one status line, shown in the composer placeholder slot.
    var composerStatusLine: String? {
        if isReadOnly { return "the radiant is beyond reach" }
        if resting { return "the radiant rests until the cycle renews" }
        return nil
    }

    /// The shared world scene (one scene, one camera — notes §1). Owned by
    /// RootView; the store only drives its focused scenario's constellation.
    let radiant: RadiantScene

    /// Transport-agnostic turn engine (SSH or gateway; routed per the ladder).
    private let modelSession: (any TurnEngine)?
    private let onPersist: @MainActor (Scenario) -> Void

    init(
        scenario: Scenario,
        modelSession: (any TurnEngine)?,
        radiant: RadiantScene,
        onPersist: @escaping @MainActor (Scenario) -> Void
    ) {
        self.scenario = scenario
        self.modelSession = modelSession
        self.radiant = radiant
        self.onPersist = onPersist
        self.analytics = TreeAnalytics(
            tree: scenario.tree, realizedPath: scenario.realizedPath, unit: scenario.payoffUnit)
        refreshScene(animated: false)
    }

    var selectedNode: Node? {
        selectedNodeId.flatMap { Tree.find(scenario.tree, id: $0) }
    }

    var selectedAnalytics: NodeAnalytics? {
        selectedNodeId.flatMap { analytics[$0] }
    }

    /// Ribbon crumbs root→selected (§2.3: ribbon + capsule are one stack).
    var ribbon: [RibbonCrumb] {
        guard let id = selectedNodeId, let path = Tree.path(scenario.tree, to: id) else {
            return []
        }
        return path.compactMap { pathId in
            Tree.find(scenario.tree, id: pathId).map { RibbonCrumb(id: pathId, label: $0.label) }
        }
    }

    /// The capsule's node context (mock 5/6): serif title, EV line, and the
    /// ridge data. All values come from PrimeRadiantCore analytics.
    var capsuleContext: CapsuleNodeContext? {
        guard let node = selectedNode else { return nil }
        let nodeAnalytics = selectedAnalytics
        let ev = nodeAnalytics?.conditionedEv ?? nodeAnalytics?.ev
        let title = node.sub.map { "\(node.label) — \($0)" } ?? node.label
        return CapsuleNodeContext(
            title: sentenceCased(title),
            evLine: EVFormatter.evLine(ev, unit: scenario.payoffUnit),
            distribution: nodeAnalytics?.conditionedDistribution ?? [],
            mean: ev,
            unit: scenario.payoffUnit,
            caption:
                "\(EVFormatter.percent(nodeAnalytics?.conditionedCumulativeProbability ?? 0)) of futures"
        )
    }

    /// Node labels are lowercase data; the capsule title renders sentence case
    /// (mock 5: "She accepts the terms").
    private func sentenceCased(_ label: String) -> String {
        guard let first = label.first else { return label }
        return first.uppercased() + label.dropFirst()
    }

    // MARK: - Selection (tap / two-finger tap / void tap)

    func select(_ id: String?) {
        guard id != selectedNodeId else { return }
        selectedNodeId = id
        isDistributionExpanded = false
        if id != nil { Haptics.selection() }
        refreshScene(animated: true)
    }

    // MARK: - Marking reality (press-and-hold, §2.3)

    func holdIntent(for id: String) -> HoldIntent {
        if scenario.realizedPath.contains(id) { return .unmark }
        if Tree.find(scenario.tree, id: id)?.isTerminal == true { return .resolve }
        return .mark
    }

    func completeHold(id: String, intent: HoldIntent) {
        guard !isReadOnly else { return }  // marking disabled quietly (pivot §3)
        do {
            switch intent {
            case .mark:
                scenario = try Marking.mark(scenario, id: id)
                touchAndRecompute()
            case .unmark:
                scenario = try Marking.unmark(scenario, id: id)
                touchAndRecompute()
            case .resolve:
                // Same ring fill, then the resolve flow offers actual-payoff entry.
                pendingResolveNodeId = id
            }
        } catch {
            lastError = "that branch is gone from the tree"
        }
    }

    func resolve(actualPayoff: Double?) {
        guard let id = pendingResolveNodeId else { return }
        pendingResolveNodeId = nil
        do {
            scenario = try Marking.resolve(scenario, terminalId: id, actualPayoff: actualPayoff)
            touchAndRecompute()
        } catch {
            lastError = "that branch is gone from the tree"
        }
    }

    /// Calibration note for the resolve sheet: actual vs the modeled estimate.
    func calibrationLine(for terminalId: String, actual: Double?) -> String? {
        guard let actual, let estimate = analytics[terminalId]?.ev else { return nil }
        let delta = actual - estimate
        let formatted = EVFormatter.compact(delta, unit: scenario.payoffUnit, signed: true)
        return "\(formatted) vs est."
    }

    // MARK: - Conversation (§2.3, §5)

    func openChat(focusedNodeId: String?) {
        self.focusedNodeId = focusedNodeId
        isChatPresented = true
    }

    func closeChat() {
        isChatPresented = false
        focusedNodeId = nil
    }

    func send(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        // Composer is quietly disabled while read-only or resting (pivot §3).
        guard composerStatusLine == nil else { return }
        guard let modelSession else { return }

        scenario.transcript.append(Message(role: .user, content: trimmed, timestamp: Date()))
        persist()

        isStreaming = true
        streamingSay = ""
        let snapshot = scenario
        let focus = focusedNodeId
        Task {
            do {
                let turn = try await modelSession.runTurn(
                    scenario: snapshot,
                    userText: trimmed,
                    focusedNodeId: focus,
                    onSayDelta: { fragment in
                        Task { @MainActor [weak self] in
                            self?.streamingSay += fragment
                        }
                    })
                self.finish(turn: turn)
            } catch {
                self.isStreaming = false
                self.streamingSay = ""
                // Quiet states, not dialogs (pivot §3): the status line in the
                // composer slot carries them.
                switch error as? ModelClientError {
                case .budgetExhausted:
                    self.resting = true
                case .boxUnreachable:
                    self.isReadOnly = true
                default:
                    self.lastError = "the radiant lost the thread · try again"
                }
            }
        }
    }

    private func finish(turn: ModelTurn) {
        isStreaming = false
        streamingSay = ""

        var patchId: String?
        if let patch = turn.patch, !patch.isEmpty {
            do {
                // Validation already dry-ran this patch; apply is transactional.
                scenario = try Patching.apply(patch, to: scenario, at: Date())
                patchId = ULID.generate()
                reorganizing = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Tokens.Layout.reflowDurationSeconds + 0.4))
                    self.reorganizing = false
                }
            } catch {
                lastError = "the futures failed to reorganize"
            }
        }
        scenario.transcript.append(
            Message(role: .assistant, content: turn.say, timestamp: Date(), patchApplied: patchId))
        touchAndRecompute()
    }

    // MARK: - Internals

    private func touchAndRecompute() {
        scenario.updatedAt = Date()
        analytics = TreeAnalytics(
            tree: scenario.tree, realizedPath: scenario.realizedPath, unit: scenario.payoffUnit)
        // Selection may have been removed by a patch.
        if let id = selectedNodeId, Tree.find(scenario.tree, id: id) == nil {
            selectedNodeId = nil
        }
        refreshScene(animated: true)
        persist()
    }

    private func refreshScene(animated: Bool) {
        radiant.setScenario(
            scenarioId: scenario.id,
            tree: scenario.tree,
            analytics: analytics,
            realizedPath: scenario.realizedPath,
            selectedId: selectedNodeId,
            unit: scenario.payoffUnit,
            animated: animated,
            resolved: scenario.status == .resolved)
    }

    private func persist() {
        onPersist(scenario)
    }

    // MARK: - Debug capture states (DEBUG only, mirrors -PRDebugSample gating)

    #if DEBUG
        /// `-PRDebugChat`: a scripted local thread (2 user + 1 assistant, generic
        /// sample-scenario content, no model calls) with the patch status line
        /// visible and the ghost tree at patch brightness. Screenshot-compare
        /// against mock 8; never compiled into release builds.
        func debugSeedChatTranscript(at date: Date) {
            scenario.transcript = [
                Message(
                    role: .user,
                    content: "They came back at 180 with the same equity.",
                    timestamp: date),
                Message(
                    role: .assistant,
                    content:
                        "Reweighting. At 180, accepting beats one more push: EV +$14k against +$11k for push-once-more. The optimal line is now: take the 180, lock the start date.",
                    timestamp: date,
                    patchApplied: ULID.generate()),
                Message(
                    role: .user,
                    content: "Do it. What do I open with?",
                    timestamp: date),
            ]
            reorganizing = true
        }
    #endif
}
