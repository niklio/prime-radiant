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

    /// The shared world scene (one scene, one camera — notes §1). Owned by
    /// RootView; the store only drives its focused scenario's constellation.
    let radiant: RadiantScene

    private let modelSession: ModelSession?
    private let onPersist: @MainActor (Scenario) -> Void

    init(
        scenario: Scenario,
        modelSession: ModelSession?,
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

    /// Breadcrumb labels root→selected (§2.3: footer + breadcrumb are one stack).
    var breadcrumb: [String] {
        guard let id = selectedNodeId, let path = Tree.path(scenario.tree, to: id) else {
            return []
        }
        return path.compactMap { Tree.find(scenario.tree, id: $0)?.label }
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
        guard let modelSession else {
            lastError = "sign in to speak to the radiant"
            return
        }

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
                self.lastError = "the radiant lost the thread · try again"
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
}
