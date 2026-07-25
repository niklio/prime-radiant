import Foundation

/// Self-provisioning over SSH (ux-update §1, screen 1c2; server/README §install):
/// the app streams the bundled `provision-bundle.sh` into `sh -s` on the box and
/// renders the three stage lines from the exact stdout marker grammar
/// (`provision.sh` header):
///
///   ##stage:reach → ##stage:plant → ##stage:wake
///   ##token:<64 lowercase hex>  ##addr:<url>
///   ##fail:<stage>:<one plain sentence>   — halt; sentence shown verbatim
///
/// Re-running the same bundle IS the retry and the upgrade mechanism (idempotent
/// script; Settings' quiet *re-provision* action goes through this same runner).

enum ProvisionStage: String, CaseIterable, Sendable {
    case reach, plant, wake
}

enum ProvisionEvent: Equatable, Sendable {
    case stage(ProvisionStage)
    case token(String)
    case addr(String)
    /// The one plain sentence, shown verbatim on the failing line.
    case fail(stage: String, message: String)
}

/// stdout → marker events. Lines that are not markers are ignored (the script
/// writes nothing else to stdout, but the parser stays defensive).
struct ProvisionMarkerParser: Sendable {
    private var lines = LineAssembler()

    mutating func feed(_ data: Data) -> [ProvisionEvent] {
        lines.feed(data).compactMap(Self.parse)
    }

    static func parse(_ line: String) -> ProvisionEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("##stage:") {
            return ProvisionStage(rawValue: String(trimmed.dropFirst("##stage:".count)))
                .map(ProvisionEvent.stage)
        }
        if trimmed.hasPrefix("##token:") {
            return .token(String(trimmed.dropFirst("##token:".count)))
        }
        if trimmed.hasPrefix("##addr:") {
            return .addr(String(trimmed.dropFirst("##addr:".count)))
        }
        if trimmed.hasPrefix("##fail:") {
            let rest = trimmed.dropFirst("##fail:".count)
            guard let colon = rest.firstIndex(of: ":") else {
                return .fail(stage: String(rest), message: "")
            }
            return .fail(
                stage: String(rest[..<colon]),
                message: String(rest[rest.index(after: colon)...]))
        }
        return nil
    }
}

struct ProvisionOutcome: Equatable, Sendable {
    var token: String
    var addr: String
}

struct ProvisionFailure: Error, Equatable, Sendable {
    var stage: String
    /// Shown verbatim under the halted stage line (1c2).
    var message: String
}

struct ProvisionRunner: Sendable {
    let box: any SSHBox

    /// The combined artifact, bundled into the app so provisioning needs no
    /// network beyond the SSH channel itself (~430KB: provision.sh + base64
    /// gateway payload).
    static func bundledScript() -> Data? {
        Bundle.main.url(forResource: "provision-bundle", withExtension: "sh")
            .flatMap { try? Data(contentsOf: $0) }
    }

    /// Stream the script into `sh -s` and drive the stage lines. Throws
    /// `ProvisionFailure` on a ##fail marker (haltingly, message verbatim).
    func run(
        script: Data,
        onEvent: @escaping @Sendable (ProvisionEvent) -> Void
    ) async throws -> ProvisionOutcome {
        let channel = try await box.execInteractive("sh -s")
        // Send in chunks: a single 430KB write is legal but chunking keeps any
        // transport window happy; sh consumes the script incrementally.
        let chunkSize = 32 * 1024
        var offset = 0
        while offset < script.count {
            let end = min(offset + chunkSize, script.count)
            try await channel.send(script.subdata(in: offset..<end))
            offset = end
        }

        var parser = ProvisionMarkerParser()
        var token: String?
        var addr: String?
        var failure: ProvisionFailure?
        do {
            for try await chunk in channel.output {
                guard case .stdout(let data) = chunk else { continue }
                for event in parser.feed(data) {
                    onEvent(event)
                    switch event {
                    case .token(let value): token = value
                    case .addr(let value): addr = value
                    case .fail(let stage, let message):
                        failure = ProvisionFailure(stage: stage, message: message)
                    case .stage:
                        break
                    }
                }
            }
        } catch is ExecFailure {
            // Non-zero exit travels with a ##fail marker; the marker is the truth.
        }
        await channel.close()

        if let failure { throw failure }
        guard let token, let addr else {
            throw ProvisionFailure(
                stage: "wake", message: "the box went quiet before finishing; retry.")
        }
        return ProvisionOutcome(token: token, addr: addr)
    }
}
