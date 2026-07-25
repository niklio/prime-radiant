import Foundation

@testable import PrimeRadiant

/// In-memory `SSHBox` for unit tests: scriptable auth flavors, host keys,
/// exec output, warm-channel turns, and an SFTP filesystem — plus a call log
/// so tests can assert exact sequences (e.g. key installation during pairing).
final class FakeBox: SSHBox, @unchecked Sendable {

    private let lock = NSRecursiveLock()

    // MARK: Connection scripting

    /// Host key presented per connect (the last one repeats).
    var hostKeys: [Data] = [Data("hostkey-A".utf8)]
    /// Tailscale flavor: `.none` credentials succeed.
    var acceptsNoneAuth = false
    /// Native sshd flavor: username → password.
    var passwords: [String: String] = [:]
    /// Set when the pairing install command ran; `.privateKey` auth succeeds after.
    var keyInstalled = false
    var unreachable = false

    private var connectCount = 0
    private var connected = false

    // MARK: Exec scripting

    /// Ordered substring handlers for one-shot exec; first match wins.
    var execHandlers: [(contains: String, stdout: String, exitCode: Int)] = []
    /// Warm-channel scripts: each stdin send pops the next entry; `nil` kills
    /// the channel instead (simulates a dropped warm process).
    var turnScripts: [[String]?] = []
    var interactiveSpawnFails = false

    // MARK: SFTP state

    var files: [String: Data] = [:]
    var directories: Set<String> = []

    private(set) var log: [String] = []

    /// Synchronous critical section (NSLock is unavailable directly in async
    /// contexts; hiding it in a sync helper is the async-safe pattern here).
    private func locked<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func record(_ entry: String) {
        locked { log.append(entry) }
    }

    // MARK: - SSHBox

    var isConnected: Bool {
        locked { connected }
    }

    @discardableResult
    func connect(address: String, auth: BoxAuth, pinnedHostKey: Data?) async throws -> Data {
        try locked {
            if unreachable {
                log.append("connect unreachable")
                throw SSHBoxError.unreachable("down")
            }
            let hostKey = hostKeys[min(connectCount, hostKeys.count - 1)]
            connectCount += 1
            switch auth {
            case .none(let username):
                log.append("connect none(\(username))")
            case .password(let username, _):
                log.append("connect password(\(username))")
            case .privateKey(let username, _):
                log.append("connect key(\(username))")
            }
            if let pinnedHostKey, pinnedHostKey != hostKey {
                throw SSHBoxError.hostKeyMismatch
            }
            switch auth {
            case .none:
                guard acceptsNoneAuth else { throw SSHBoxError.authenticationFailed }
            case .password(let username, let password):
                guard passwords[username] == password else {
                    throw SSHBoxError.authenticationFailed
                }
            case .privateKey:
                guard keyInstalled else { throw SSHBoxError.authenticationFailed }
            }
            connected = true
            return hostKey
        }
    }

    func disconnect() async {
        locked {
            connected = false
            log.append("disconnect")
        }
    }

    func exec(_ command: String) async throws -> AsyncThrowingStream<ExecChunk, Error> {
        locked {
            log.append("exec \(command)")
            if command.contains("authorized_keys") {
                keyInstalled = true
            }
            let handler = execHandlers.first { command.contains($0.contains) }
            let stdout = handler?.stdout ?? ""
            let exitCode = handler?.exitCode ?? 0
            let (stream, continuation) = AsyncThrowingStream<ExecChunk, Error>.makeStream()
            if !stdout.isEmpty {
                continuation.yield(.stdout(Data(stdout.utf8)))
            }
            if exitCode == 0 {
                continuation.finish()
            } else {
                continuation.finish(throwing: ExecFailure(exitCode: exitCode))
            }
            return stream
        }
    }

    func execInteractive(_ command: String) async throws -> ExecChannel {
        try locked {
            log.append("spawn \(command)")
            if interactiveSpawnFails {
                throw SSHBoxError.channelFailed
            }
            let (output, continuation) = AsyncThrowingStream<ExecChunk, Error>.makeStream()
            return ExecChannel(
                output: output,
                send: { [weak self] data in
                    guard let self else { throw SSHBoxError.channelFailed }
                    self.locked {
                        self.log.append("stdin \(String(decoding: data, as: UTF8.self))")
                        guard !self.turnScripts.isEmpty,
                            let script = self.turnScripts.removeFirst()
                        else {
                            continuation.finish()  // channel died
                            return
                        }
                        for line in script {
                            continuation.yield(.stdout(Data((line + "\n").utf8)))
                        }
                    }
                },
                close: { [weak self] in
                    self?.record("close-warm")
                    continuation.finish()
                })
        }
    }

    // MARK: SFTP (parent directory must exist — asserts mkdir-p behavior)

    func sftpRead(path: String) async throws -> Data {
        try locked {
            log.append("read \(path)")
            guard let data = files[path] else { throw SSHBoxError.fileNotFound(path) }
            return data
        }
    }

    func sftpWrite(path: String, data: Data) async throws {
        try locked {
            log.append("write \(path)")
            let parent = (path as NSString).deletingLastPathComponent
            guard directories.contains(parent) else { throw SSHBoxError.channelFailed }
            files[path] = data
        }
    }

    func sftpList(directory: String) async throws -> [String] {
        try locked {
            log.append("list \(directory)")
            guard directories.contains(directory) else {
                throw SSHBoxError.fileNotFound(directory)
            }
            return files.keys
                .filter { ($0 as NSString).deletingLastPathComponent == directory }
                .map { ($0 as NSString).lastPathComponent }
                .sorted()
        }
    }

    func sftpMkdir(path: String) async throws {
        locked {
            log.append("mkdir \(path)")
            directories.insert(path)
        }
    }

    func sftpRename(from: String, to: String) async throws {
        try locked {
            log.append("rename \(from) -> \(to)")
            guard let data = files.removeValue(forKey: from) else {
                throw SSHBoxError.fileNotFound(from)
            }
            files[to] = data
        }
    }

    func sftpRemove(path: String) async throws {
        try locked {
            log.append("remove \(path)")
            guard files.removeValue(forKey: path) != nil else {
                throw SSHBoxError.fileNotFound(path)
            }
        }
    }
}

// MARK: - Stream-json line builders (shapes verified against claude CLI 2.1.178)

enum StreamJSON {
    static func textDelta(_ text: String) -> String {
        let escaped = jsonEscaped(text)
        return #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(escaped)"}}}"#
    }

    static func thinkingDelta(_ text: String) -> String {
        let escaped = jsonEscaped(text)
        return #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"\#(escaped)"}}}"#
    }

    static func result(_ text: String, isError: Bool = false) -> String {
        let escaped = jsonEscaped(text)
        let subtype = isError ? "error_during_execution" : "success"
        return #"{"type":"result","subtype":"\#(subtype)","is_error":\#(isError),"result":"\#(escaped)","session_id":"fake","num_turns":1}"#
    }

    private static func jsonEscaped(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data()
        let wrapped = String(decoding: data, as: UTF8.self)
        return String(wrapped.dropFirst(2).dropLast(2))
    }
}
