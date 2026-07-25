import Foundation
import Observation
import UIKit

/// The staged pairing/provisioning state machine (ux-update §1, screens
/// 1b → 1b2/1b3 → 1c2/1c → 1d), free of UI so every branch runs against fakes:
///
///   1b address ──submit──▶ probe:
///     gateway already running (paired:false) ─▶ 1c code
///     Tailscale SSH (no creds)               ─▶ 1c2 provisioning ─▶ 1d
///     plain sshd                             ─▶ 1b3 credentials ─▶ 1c2 ─▶ 1d
///     unreachable                            ─▶ 1b2 (inline, not a screen)
///
/// The probe order is the doc's: existing gateway → Tailscale SSH → plain sshd.
/// Editing the field is the retry; provisioning re-runs are idempotent.
@MainActor
@Observable
final class PairingController: Identifiable {

    /// Item-based presentation identity (fullScreenCover(item:)).
    nonisolated let id = UUID()

    enum Stage: Equatable {
        case address
        case credentials
        case provisioning
        case code
        case paired
    }

    enum StageLineState: Equatable {
        case pending
        case active
        case done
        /// Halted with the script's one plain sentence, shown verbatim.
        case failed(String)
    }

    // MARK: Observable state (the view renders exactly this)

    private(set) var stage: Stage = .address
    var address = ""
    var username = ""
    var password = ""
    /// 1b2: the same screen's failure state — never a screen change.
    private(set) var unreachable = false
    /// Node pulses ~1/s while probing (no spinner exists in this app).
    private(set) var probing = false
    /// One in-voice line under the credential fields (wrong password etc.).
    private(set) var credentialLine: String?

    private(set) var reach: StageLineState = .pending
    private(set) var plant: StageLineState = .pending
    private(set) var wake: StageLineState = .pending

    /// 1c: up to six characters; auto-submitted when full.
    var code = ""
    /// Increments on a rejected code → shake-and-clear + error haptic.
    private(set) var codeRejections = 0

    /// The address shown gold beneath the ignited node (1d).
    private(set) var pairedAddress = ""

    /// Set when the flow lands: the caller adopts it into the Keychain.
    private(set) var pairedRecord: PairedBox?

    // MARK: Dependencies

    private let box: any SSHBox
    private let gateway: any GatewayAPI
    private let provisionScript: () -> Data?
    private let makeKey: (@Sendable () -> Data)?
    private let onPaired: @MainActor (PairedBox) -> Void

    /// Base that answered the health probe (code-pairing target).
    private var probedBase: URL?
    /// SSH record established before provisioning (augmented with token+addr).
    private var sshRecord: PairedBox?
    private var task: Task<Void, Never>?

    init(
        box: any SSHBox,
        gateway: any GatewayAPI = LiveGatewayClient(),
        provisionScript: @escaping () -> Data? = { ProvisionRunner.bundledScript() },
        makeKey: (@Sendable () -> Data)? = nil,
        onPaired: @escaping @MainActor (PairedBox) -> Void
    ) {
        self.box = box
        self.gateway = gateway
        self.provisionScript = provisionScript
        self.makeKey = makeKey
        self.onPaired = onPaired
    }

    /// Re-provision entry (Settings' quiet update mechanism): jump straight to
    /// the stage lines over the already-paired record.
    func beginReprovision(record: PairedBox) {
        sshRecord = record
        address = record.address
        stage = .provisioning
        startProvisioning()
    }

    // MARK: - 1b: submit → probe ladder

    func submitAddress() {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !probing else { return }
        unreachable = false
        probing = true
        task = Task { [weak self] in
            await self?.probe(trimmed)
        }
    }

    /// Typing again IS the retry: the unreachable line fades as editing resumes.
    func addressEdited() {
        unreachable = false
    }

    private func probe(_ addressText: String) async {
        defer { probing = false }

        // 1. An existing gateway answering /v1/health.
        for base in GatewayAddress.candidates(for: addressText) {
            guard let health = await gateway.health(base: base) else { continue }
            probedBase = base
            if !health.paired {
                // Hand-installed, unpaired → the code fallback (1c).
                stage = .code
                return
            }
            // Paired gateway but this device holds no token → provision over
            // SSH (idempotent; returns the existing token in-band).
            break
        }

        // 2–3. Tailscale SSH, then plain sshd (the flow challenges).
        await connectAndProvision(addressText: addressText, password: nil)
    }

    // MARK: - 1b3: credentials (plain-sshd path only)

    func submitCredentials() {
        let user = username.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty, !password.isEmpty, !probing else { return }
        credentialLine = nil
        probing = true
        let addressText = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password
        task = Task { [weak self] in
            await self?.connectAndProvision(addressText: addressText, password: secret)
            self?.probing = false
        }
    }

    private func connectAndProvision(addressText: String, password: String?) async {
        var flow = PairingFlow(box: box)
        if let makeKey { flow.makeKey = makeKey }
        // 1b carries no username field; the Tailscale probe rides the guessed
        // short name. 1b3's `user` field overrides it on the plain-sshd path.
        var user = username.trimmingCharacters(in: .whitespaces)
        if user.isEmpty { user = Self.guessUsername() }
        let outcome = await flow.pair(
            address: addressText, username: user, password: password)
        switch outcome {
        case .paired(let record):
            sshRecord = record
            // Credentials were used once for the key install inside the flow;
            // they are discarded now, before provisioning begins.
            self.password = ""
            stage = .provisioning
            startProvisioning()
        case .needsPassword:
            if stage == .address {
                stage = .credentials
            } else {
                credentialLine = "the box asks for its system password"
            }
        case .failed(let message):
            if stage == .credentials {
                credentialLine = message
            } else {
                // 1b2: inline state on the same screen; editing is the retry.
                unreachable = true
            }
        }
    }

    // MARK: - 1c2: provisioning (stream the bundle, render the stage lines)

    /// Tap-anywhere after a halt re-runs the idempotent script.
    func retryProvisioning() {
        guard case .failed = failedLine() else { return }
        startProvisioning()
    }

    private func failedLine() -> StageLineState {
        for line in [reach, plant, wake] {
            if case .failed = line { return line }
        }
        return .pending
    }

    private func startProvisioning() {
        reach = .pending
        plant = .pending
        wake = .pending
        guard let script = provisionScript() else {
            reach = .failed("the app is missing its provisioning payload.")
            return
        }
        let runner = ProvisionRunner(box: box)
        let applyEvent: @MainActor @Sendable (ProvisionEvent) -> Void = { [weak self] in
            self?.apply($0)
        }
        task = Task { [weak self] in
            do {
                let outcome = try await runner.run(script: script) { event in
                    Task { await applyEvent(event) }
                }
                self?.finishProvisioning(outcome: outcome)
            } catch let failure as ProvisionFailure {
                self?.halt(failure)
            } catch {
                self?.halt(
                    ProvisionFailure(
                        stage: "reach", message: "the channel to the box dropped; retry."))
            }
        }
    }

    private func apply(_ event: ProvisionEvent) {
        switch event {
        case .stage(.reach):
            reach = .active
        case .stage(.plant):
            reach = .done
            plant = .active
        case .stage(.wake):
            plant = .done
            wake = .active
        case .fail(let stage, let message):
            halt(ProvisionFailure(stage: stage, message: message))
        case .token, .addr:
            break
        }
    }

    private func halt(_ failure: ProvisionFailure) {
        let state = StageLineState.failed(failure.message)
        switch ProvisionStage(rawValue: failure.stage) {
        case .reach: reach = state
        case .plant: plant = state
        case .wake: wake = state
        case nil: reach = state
        }
    }

    private func finishProvisioning(outcome: ProvisionOutcome) {
        wake = .done
        guard var record = sshRecord else { return }
        record.deviceToken = outcome.token
        record.gatewayAddress = outcome.addr
        land(record: record, shownAddress: address)
    }

    // MARK: - 1c: code fallback (hand-installed servers)

    func codeEdited() {
        // Uppercase, six cells, auto-submit when full (wrong code → shake).
        code = String(code.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(6))
        if code.count == 6 {
            submitCode()
        }
    }

    private func submitCode() {
        guard let base = probedBase, !probing else { return }
        probing = true
        let entered = code
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await self.gateway.pair(base: base, code: entered)
                var record = PairedBox(
                    address: self.address.trimmingCharacters(in: .whitespacesAndNewlines),
                    username: "", flavor: .gateway, hostKeyPin: Data(),
                    privateKeyRaw: nil, apiKeyWarning: false)
                record.deviceToken = token
                record.gatewayAddress = base.absoluteString
                self.probing = false
                self.land(record: record, shownAddress: self.address)
            } catch {
                self.probing = false
                self.code = ""
                self.codeRejections += 1
            }
        }
    }

    // MARK: - 1d: paired

    private func land(record: PairedBox, shownAddress: String) {
        pairedRecord = record
        pairedAddress = shownAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        stage = .paired
    }

    /// Called by the view when the 1d frame has played (<1s): persist + fly home.
    func completePairing() {
        guard let record = pairedRecord else { return }
        onPaired(record)
    }

    /// The common case for a personal Mac: the owner's short name, guessed from
    /// the device name ("Nik's iPhone" → "nik"). Editable on 1b3.
    static func guessUsername() -> String {
        let name = UIDevice.current.name
        let first = name.split(separator: " ").first.map(String.init) ?? ""
        let stem = first.split(separator: "'").first.map(String.init) ?? first
        return stem.lowercased().filter { $0.isLetter }
    }

    // MARK: - Deterministic capture states (DEBUG only)

    #if DEBUG
        /// `-PRDebugPairingState=<state>` value, if present.
        static func debugStateArgument() -> String? {
            for argument in ProcessInfo.processInfo.arguments
            where argument.hasPrefix("-PRDebugPairingState=") {
                return String(argument.dropFirst("-PRDebugPairingState=".count))
            }
            return nil
        }

        /// Render one screen deterministically with representative content
        /// (mocks 1b–1d capture loop). Never compiled into release builds.
        func applyDebugState(_ name: String) {
            let sampleAddress = "radiant.fern-lake.ts.net"
            switch name {
            case "address":
                stage = .address
            case "unreachable":
                stage = .address
                address = sampleAddress
                unreachable = true
            case "credentials":
                stage = .credentials
                address = sampleAddress
                password = "••••••••"
            case "provisioning":
                stage = .provisioning
                reach = .done
                plant = .active
                wake = .pending
            case "fail":
                stage = .provisioning
                reach = .done
                plant = .failed("run claude login on the box, then retry.")
                wake = .pending
            case "code":
                stage = .code
                address = sampleAddress
                code = "7K4"
            case "paired":
                stage = .paired
                pairedAddress = sampleAddress
            default:
                break
            }
        }
    #endif
}
