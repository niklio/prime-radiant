import PrimeRadiantCore
import SwiftData
import SwiftUI

/// App entry. Routing (pivot v3): ignition (pairing) → constellation home →
/// scenario canvas. Scenarios persist locally in SwiftData (client is source
/// of truth while open) and sync to the paired box over SFTP in the background.
/// If the box is beyond reach the app opens read-only — quietly (pivot §3).
@main
struct PrimeRadiantApp: App {
    private let config: BoxConfig
    @State private var session: BoxSession

    init() {
        config = BoxConfig.load()
        _session = State(initialValue: BoxSession())
    }

    var body: some Scene {
        WindowGroup {
            RootView(session: session, config: config)
                .preferredColorScheme(.dark)
        }
        .modelContainer(for: StoredScenario.self)
    }
}

struct RootView: View {
    @Bindable var session: BoxSession
    let config: BoxConfig

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoredScenario.updatedAt, order: .reverse)
    private var stored: [StoredScenario]

    /// The one world scene (notes §1): home and canvas are the same scene
    /// viewed from two camera states. Created once, never swapped.
    @State private var world = RadiantScene(reduceMotion: Motion.isReduced)
    /// The open scenario's store; nil means the constellation is home.
    @State private var openStore: ScenarioStore?
    /// Canvas overlays hide during flights (chrome crossfades at the
    /// endpoints only — notes §3).
    @State private var overlaysVisible = true
    @State private var sync: BoxSync?
    @State private var showSettings = false

    var body: some View {
        Group {
            if session.isPaired || Self.debugSampleMode {
                home
            } else {
                // Unpair lands back here — the ignition screen (pivot v3:
                // anywhere-tap opens the pairing sheet).
                IgnitionView(session: session)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: session.isPaired)
        .onChange(of: session.isPaired, initial: true) { _, paired in
            if paired {
                sync = makeSync()
                Task {
                    await session.ensureConnected()
                    await pullOnOpen()
                }
            } else {
                sync = nil
                if !Self.debugSampleMode { openStore = nil }
            }
        }
        .onChange(of: session.reachable) { _, reachable in
            // Box unreachable → read-only, "the radiant is beyond reach"; no
            // dialogs, ever (pivot §3). Debug sample mode stays interactive.
            openStore?.isReadOnly = !reachable && !Self.debugSampleMode
        }
        .task { seedDebugSampleIfNeeded() }
    }

    /// Dev-only canvas entry (M1): `-PRDebugSample` seeds the bundled sample
    /// scenario plus two synthetic siblings (so home is a real constellation)
    /// and opens the sample directly, bypassing pairing the way it bypassed
    /// auth. `-PRDebugHome` seeds the same set but stays home; `-PRDebugEmpty`
    /// stays home with zero scenarios. The capture states (`-PRDebugSelect`,
    /// `-PRDebugDistribution`, `-PRDebugMark`, `-PRDebugChat`, `-PRDebugVoice`)
    /// render each mock row deterministically for the screenshot-compare loop.
    /// Chat and sync stay dark. Never compiled into release builds.
    static var debugSampleMode: Bool {
        #if DEBUG
            let flags = [
                "-PRDebugSample", "-PRDebugHome", "-PRDebugEmpty", "-PRDebugSelect",
                "-PRDebugDistribution", "-PRDebugMark", "-PRDebugChat", "-PRDebugVoice",
            ]
            return flags.contains { ProcessInfo.processInfo.arguments.contains($0) }
        #else
            return false
        #endif
    }

    private func seedDebugSampleIfNeeded() {
        #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            guard Self.debugSampleMode, openStore == nil else { return }
            // `-PRDebugEmpty`: home with zero scenarios — purge anything a
            // previous debug run seeded, seed nothing.
            guard !args.contains("-PRDebugEmpty") else {
                for record in stored { modelContext.delete(record) }
                try? modelContext.save()
                world.setScenarios([])
                return
            }
            guard let url = Bundle.main.url(forResource: "job-offer", withExtension: "json"),
                let data = try? Data(contentsOf: url)
            else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let sample = try? decoder.decode(Scenario.self, from: data) else { return }
            persist(sample)
            for extra in DebugSeed.extraScenarios() { persist(extra) }
            world.setScenarios(activeScenarios)
            if args.contains("-PRDebugHome") { return }
            let store = makeStore(for: sample)
            openStore = store
            world.flyToCanvas(scenarioId: sample.id)

            // Deterministic capture states over the sample tree.
            let counter = (sample.tree.children ?? []).max(by: { $0.p < $1.p })
            if args.contains("-PRDebugMark"), let counter {
                store.completeHold(id: counter.id, intent: .mark)
            }
            if args.contains("-PRDebugSelect") || args.contains("-PRDebugDistribution") {
                // Two levels deep along max-p so the ribbon shows a real
                // ancestor run (mock 5) and the ridge has a distribution.
                let deep = (counter?.children ?? []).max(by: { $0.p < $1.p })
                store.select((deep ?? counter)?.id)
            }
            if args.contains("-PRDebugDistribution") {
                store.isDistributionExpanded = true
            }
            if args.contains("-PRDebugChat") {
                store.debugSeedChatTranscript(at: Date())
                store.openChat(focusedNodeId: nil)
            }
        #endif
    }

    /// One persistent SCNView over the one persistent scene; only the
    /// overlays and the interaction mode change between home and canvas.
    @ViewBuilder
    private var home: some View {
        ZStack {
            canvas
                .ignoresSafeArea()

            if let store = openStore {
                if overlaysVisible {
                    ScenarioView(store: store)
                        .transition(.opacity)
                }
            } else {
                ConstellationView(
                    radiant: world,
                    scenarios: activeScenarios,
                    archivedCount: stored.filter { $0.archivedAt != nil && $0.deletedAt == nil }.count,
                    onOpen: { open(id: $0) },
                    onCreate: createScenario,
                    onArchive: { archive(id: $0) },
                    onDelete: { delete(id: $0) },
                    onUndoDelete: { undoDelete(id: $0) })
                    .transition(.opacity)
                    .overlay(alignment: .bottomTrailing) { settingsButton }
            }
        }
        .background(Tokens.Role.background)
        .animation(.easeInOut(duration: 0.25), value: overlaysVisible)
        .onChange(of: activeScenarios.map(\.updatedAt)) {
            world.setScenarios(activeScenarios)
        }
        .onAppear {
            world.setScenarios(activeScenarios)
            world.onZoomOutToHome = { goHome() }
            world.onZoomIntoCluster = { open(id: $0) }
        }
        .sheet(isPresented: $showSettings) {
            BoxSettingsView(session: session)
                .presentationDetents([.medium])
        }
    }

    private var canvas: CanvasView {
        var canvas = CanvasView(
            radiant: world,
            interactive: true,
            callbacks: CanvasCallbacks(
                onSelect: { openStore?.select($0) },
                holdIntent: { openStore?.holdIntent(for: $0) ?? .mark },
                onHoldCompleted: { id, intent in openStore?.completeHold(id: id, intent: intent) },
                onTapCluster: { open(id: $0) }))
        #if DEBUG
            // UI-test hooks (§8): per-node accessibility elements + canvas state,
            // only under `-PRUITestHooks` (mirrors -PRDebugSample gating).
            if UITestHooks.enabled {
                let openStore = self.openStore
                canvas.hooksState = {
                    guard let store = openStore else {
                        return CanvasHooksState(nodeLabels: [:], stateValue: "home")
                    }
                    var labels: [String: String] = [:]
                    Tree.forEach(store.scenario.tree) { labels[$0.id] = $0.label }
                    return CanvasHooksState(
                        nodeLabels: labels,
                        stateValue:
                            "selected=\(store.selectedNodeId ?? "none") reached=\(store.scenario.realizedPath.count)"
                    )
                }
            }
        #endif
        return canvas
    }

    // The canvas carries no chrome bars and no home button (mocks 4–7, 9):
    // pinching out far enough is the flight home (gesture lexicon, notes §2).

    /// Quiet corner entry to the paired-box surface (paired box + unpair).
    @ViewBuilder
    private var settingsButton: some View {
        if session.isPaired {
            Button {
                showSettings = true
            } label: {
                Text("· box ·")
                    .font(Tokens.Fonts.mono(10))
                    .tracking(1.5)
                    .foregroundStyle(Tokens.Role.secondaryInfo.opacity(0.5))
                    .padding(16)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("the box")
            .accessibilityIdentifier("home.box")
        }
    }

    private var activeScenarios: [Scenario] {
        stored
            .filter { $0.archivedAt == nil && $0.deletedAt == nil }
            .compactMap { $0.decoded() }
    }

    // MARK: - Scenario lifecycle (flights, not swaps — notes §3)

    private func open(id: String) {
        guard openStore == nil || openStore?.scenario.id != id else { return }
        guard let scenario = stored.first(where: { $0.id == id })?.decoded() else { return }
        let store = makeStore(for: scenario)  // builds the focused constellation
        openStore = store
        overlaysVisible = false
        world.flyToCanvas(scenarioId: scenario.id) {
            overlaysVisible = true
        }
        Task { await pullNewerCopy(id: id) }
    }

    private func goHome() {
        openStore?.select(nil)
        overlaysVisible = false
        world.flyHome {
            openStore = nil
            overlaysVisible = true
            world.setScenarios(activeScenarios)
        }
    }

    private func createScenario() {
        // A blank canvas still has a root: turn 1 elicits or draws over it (§2.4);
        // the model retitles via `retitle_scenario`.
        let now = Date()
        let scenario = Scenario(
            id: ULID.generate(),
            title: "untitled",
            createdAt: now,
            updatedAt: now,
            payoffUnit: PayoffUnit(kind: .currency, label: "USD"),
            status: .modeling,
            tree: Node(id: ULID.generate(), label: "the decision", p: 1, actor: .user))
        persist(scenario)
        let store = makeStore(for: scenario)
        openStore = store
        overlaysVisible = false
        world.flyToCanvas(scenarioId: scenario.id) {
            overlaysVisible = true
        }
    }

    private func makeStore(for scenario: Scenario) -> ScenarioStore {
        let backend = ClaudeSSHBackend(
            box: session.box,
            ensureConnected: { @MainActor in await session.ensureConnected() })
        let store = ScenarioStore(
            scenario: scenario,
            modelSession: ModelSession(backend: backend, config: config),
            radiant: world,
            onPersist: { persist($0) })
        store.isReadOnly = session.isPaired && !session.reachable && !Self.debugSampleMode
        return store
    }

    /// Autosave every patch locally, then push-on-change (LWW) in the background.
    private func persist(_ scenario: Scenario) {
        do {
            if let existing = stored.first(where: { $0.id == scenario.id }) {
                try existing.update(from: scenario)
            } else {
                modelContext.insert(try StoredScenario(scenario: scenario))
            }
            try modelContext.save()
        } catch {
            return
        }
        guard let sync else { return }
        Task {
            if case .superseded(let box) = try? await sync.push(scenario) {
                adopt(box)
            }
        }
    }

    private func adopt(_ newer: Scenario) {
        if let existing = stored.first(where: { $0.id == newer.id }) {
            try? existing.update(from: newer)
            try? modelContext.save()
        }
        // If it's the open scenario, the next open picks up the box copy;
        // live in-place merge is M3 sync hardening.
    }

    private func archive(id: String) {
        stored.first(where: { $0.id == id })?.archivedAt = Date()
        try? modelContext.save()
    }

    private func delete(id: String) {
        guard let record = stored.first(where: { $0.id == id }) else { return }
        record.deletedAt = Date()
        try? modelContext.save()
        if let scenario = record.decoded() {
            Task { try? await sync?.softDelete(scenario) }
        }
    }

    private func undoDelete(id: String) {
        stored.first(where: { $0.id == id })?.deletedAt = nil
        try? modelContext.save()
        Task { _ = try? await sync?.restore(id: id) }
    }

    // MARK: - Sync (pull on open, LWW — handoff §6 over SFTP)

    private func makeSync() -> BoxSync {
        BoxSync(
            box: session.box,
            ensureConnected: { @MainActor in await session.ensureConnected() })
    }

    private func pullOnOpen() async {
        guard let sync else { return }
        guard let remote = try? await sync.pullAll() else { return }
        for scenario in remote {
            if let local = stored.first(where: { $0.id == scenario.id }),
                scenario.updatedAt <= local.updatedAt {
                continue
            }
            adoptOrInsert(scenario)
        }
        // Opportunistic 30-day trash purge (pivot v3: the app is the only agent).
        try? await sync.purgeTrash()
    }

    private func pullNewerCopy(id: String) async {
        guard let sync, let scenario = try? await sync.pull(id: id) else { return }
        if let local = stored.first(where: { $0.id == id }),
            scenario.updatedAt > local.updatedAt {
            adoptOrInsert(scenario)
        }
    }

    private func adoptOrInsert(_ scenario: Scenario) {
        if let existing = stored.first(where: { $0.id == scenario.id }) {
            try? existing.update(from: scenario)
        } else {
            if let fresh = try? StoredScenario(scenario: scenario) {
                modelContext.insert(fresh)
            }
        }
        try? modelContext.save()
    }
}

#if DEBUG
    /// Synthetic companion scenarios for `-PRDebugSample` / `-PRDebugHome`:
    /// home must read as a constellation field (mock 10), so the bundled sample
    /// gets two stable siblings. Fixed ids → stable shell coordinates.
    enum DebugSeed {
        static func extraScenarios() -> [Scenario] {
            let unit = PayoffUnit(kind: .currency, label: "USD")
            let past = Date(timeIntervalSinceNow: -86_400 * 2)

            func node(
                _ id: String, _ label: String, p: Double,
                payoff: Double? = nil, children: [Node]? = nil
            ) -> Node {
                Node(
                    id: id, label: label, p: p, actor: .counterpart,
                    payoff: payoff.map { .scalar($0) }, children: children)
            }

            let launch = Scenario(
                id: "01J0PRSEEDLAVNCH0000000001",
                title: "Launch timing",
                createdAt: past, updatedAt: past,
                payoffUnit: unit, status: .modeling,
                tree: node(
                    "01J0PRSEEDLAVNCH00000000R0", "ship now or wait", p: 1,
                    children: [
                        node(
                            "01J0PRSEEDLAVNCH00000000A0", "ship this month", p: 0.55,
                            children: [
                                node("01J0PRSEEDLAVNCH00000000A1", "press covers it", p: 0.4, payoff: 9000),
                                node("01J0PRSEEDLAVNCH00000000A2", "quiet launch", p: 0.6, payoff: 2500),
                            ]),
                        node(
                            "01J0PRSEEDLAVNCH00000000B0", "wait for the fair", p: 0.45,
                            children: [
                                node("01J0PRSEEDLAVNCH00000000B1", "rival ships first", p: 0.35, payoff: -4000),
                                node("01J0PRSEEDLAVNCH00000000B2", "bigger splash", p: 0.65, payoff: 12000),
                            ]),
                    ]))

            let vendor = Scenario(
                id: "01J0PRSEEDVEND0R0000000002",
                title: "Vendor renewal",
                createdAt: past, updatedAt: Date(timeIntervalSinceNow: -86_400 * 5),
                payoffUnit: unit, status: .resolved,
                tree: node(
                    "01J0PRSEEDVEND0R00000000R0", "renew or switch", p: 1,
                    children: [
                        node(
                            "01J0PRSEEDVEND0R00000000A0", "renew at list", p: 0.3,
                            payoff: -6000),
                        node(
                            "01J0PRSEEDVEND0R00000000B0", "negotiate", p: 0.7,
                            children: [
                                node("01J0PRSEEDVEND0R00000000B1", "they discount", p: 0.6, payoff: 8000),
                                node("01J0PRSEEDVEND0R00000000B2", "they hold", p: 0.4, payoff: -1500),
                            ]),
                    ]),
                realizedPath: [
                    "01J0PRSEEDVEND0R00000000R0",
                    "01J0PRSEEDVEND0R00000000B0",
                    "01J0PRSEEDVEND0R00000000B1",
                ],
                resolvedPayoff: 8000)

            return [launch, vendor]
        }
    }
#endif
