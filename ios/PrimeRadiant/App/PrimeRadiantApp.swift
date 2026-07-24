import PrimeRadiantCore
import SwiftData
import SwiftUI

/// App entry. Routing (§2.1–§2.3): ignition (onboarding/OAuth) → constellation
/// home → scenario canvas. Scenarios persist locally in SwiftData (client is
/// source of truth while open, §6) and sync to the Worker in the background.
@main
struct PrimeRadiantApp: App {
    private let config: RemoteConfig
    @State private var auth: OpenAIAuth

    init() {
        let config = RemoteConfig.load()
        self.config = config
        _auth = State(initialValue: OpenAIAuth(config: config.oauth))
    }

    var body: some Scene {
        WindowGroup {
            RootView(auth: auth, config: config)
                .preferredColorScheme(.dark)
        }
        .modelContainer(for: StoredScenario.self)
    }
}

struct RootView: View {
    @Bindable var auth: OpenAIAuth
    let config: RemoteConfig

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoredScenario.updatedAt, order: .reverse)
    private var stored: [StoredScenario]

    /// The open scenario's store; nil means the constellation is home.
    @State private var openStore: ScenarioStore?
    @State private var sync: SyncClient?

    var body: some View {
        Group {
            if isSignedIn || Self.debugSampleMode {
                home
            } else {
                // Revocation/unlink lands back here — the ignition screen (§2.1).
                IgnitionView(auth: auth)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: auth.state == .signedOut)
        .onChange(of: isSignedIn, initial: true) { _, signedIn in
            if signedIn {
                sync = makeSyncClient()
                Task { await pullOnOpen() }
            } else {
                sync = nil
                if !Self.debugSampleMode { openStore = nil }
            }
        }
        .task { seedDebugSampleIfNeeded() }
    }

    /// Dev-only canvas entry (M1): `-PRDebugSample` seeds the bundled sample
    /// scenario and opens it directly, skipping auth. Chat and sync stay dark —
    /// this exists so canvas work and UI tests don't need a live OAuth client.
    /// Never compiled into release builds; no fallback auth mode exists (§2.1).
    static var debugSampleMode: Bool {
        #if DEBUG
            ProcessInfo.processInfo.arguments.contains("-PRDebugSample")
        #else
            false
        #endif
    }

    private func seedDebugSampleIfNeeded() {
        #if DEBUG
            guard Self.debugSampleMode, openStore == nil else { return }
            guard let url = Bundle.main.url(forResource: "job-offer", withExtension: "json"),
                let data = try? Data(contentsOf: url)
            else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let sample = try? decoder.decode(Scenario.self, from: data) else { return }
            persist(sample)
            openStore = makeStore(for: sample)
        #endif
    }

    private var isSignedIn: Bool {
        if case .signedIn = auth.state { return true }
        return false
    }

    @ViewBuilder
    private var home: some View {
        if let store = openStore {
            ScenarioView(store: store)
                .transition(.opacity)
                .overlay(alignment: .topLeading) { homeButton }
        } else {
            ConstellationView(
                scenarios: activeScenarios,
                archivedCount: stored.filter { $0.archivedAt != nil && $0.deletedAt == nil }.count,
                onOpen: { open(id: $0) },
                onCreate: createScenario,
                onArchive: { archive(id: $0) },
                onDelete: { delete(id: $0) },
                onUndoDelete: { undoDelete(id: $0) })
        }
    }

    /// Single quiet exit from the canvas back to the constellation. Sparse by
    /// design; the canvas itself carries no chrome bars (§2.3).
    private var homeButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.35)) { openStore = nil }
        } label: {
            Text("‹")
                .font(Tokens.Fonts.mono(20))
                .foregroundStyle(Tokens.Role.secondaryInfo.opacity(0.7))
                .padding(14)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("constellation")
    }

    private var activeScenarios: [Scenario] {
        stored
            .filter { $0.archivedAt == nil && $0.deletedAt == nil }
            .compactMap { $0.decoded() }
    }

    // MARK: - Scenario lifecycle

    private func open(id: String) {
        guard let scenario = stored.first(where: { $0.id == id })?.decoded() else { return }
        openStore = makeStore(for: scenario)
        Task { await pullNewerCopy(id: id) }
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
        openStore = makeStore(for: scenario)
    }

    private func makeStore(for scenario: Scenario) -> ScenarioStore {
        let backend = OpenAIResponsesBackend(
            config: config.openAI,
            accessToken: { try await auth.validAccessToken() })
        return ScenarioStore(
            scenario: scenario,
            modelSession: ModelSession(backend: backend, config: config.openAI),
            onPersist: { persist($0) })
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
            if case .superseded(let server) = try? await sync.push(scenario) {
                adopt(server)
            }
        }
    }

    private func adopt(_ server: Scenario) {
        if let existing = stored.first(where: { $0.id == server.id }) {
            try? existing.update(from: server)
            try? modelContext.save()
        }
        // If it's the open scenario, the next open picks up the server copy;
        // live in-place merge is M3 sync hardening.
    }

    private func archive(id: String) {
        stored.first(where: { $0.id == id })?.archivedAt = Date()
        try? modelContext.save()
    }

    private func delete(id: String) {
        stored.first(where: { $0.id == id })?.deletedAt = Date()
        try? modelContext.save()
        Task { try? await sync?.delete(id: id) }
    }

    private func undoDelete(id: String) {
        stored.first(where: { $0.id == id })?.deletedAt = nil
        try? modelContext.save()
        Task { try? await sync?.restore(id: id) }
    }

    // MARK: - Sync (pull on open, §6)

    private func makeSyncClient() -> SyncClient {
        SyncClient(
            baseURL: config.sync.baseURL,
            identityToken: { await auth.identityToken })
    }

    private func pullOnOpen() async {
        guard let sync else { return }
        guard let remote = try? await sync.listScenarios() else { return }
        for metadata in remote {
            let local = stored.first(where: { $0.id == metadata.id })
            let remoteUpdated = ISO8601DateFormatter.flexible(metadata.updatedAt)
            if let local, let remoteUpdated, remoteUpdated <= local.updatedAt { continue }
            if let scenario = try? await sync.fetchScenario(id: metadata.id) {
                adoptOrInsert(scenario)
            }
        }
    }

    private func pullNewerCopy(id: String) async {
        guard let sync, let scenario = try? await sync.fetchScenario(id: id) else { return }
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

extension ISO8601DateFormatter {
    static func flexible(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
