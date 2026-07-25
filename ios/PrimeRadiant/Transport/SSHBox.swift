import Foundation

/// The box contract (pivot v3, SSH-native): there is no box-side component at
/// all. The app embeds an SSH client and carries the entire protocol — exec
/// channels for `claude` turns, SFTP for scenario sync. Everything above the
/// transport (pairing, chat, sync) depends on this protocol only, so tests run
/// against a `FakeBox` and the Citadel implementation stays swappable.

/// One chunk of remote process output.
enum ExecChunk: Sendable, Equatable {
    case stdout(Data)
    case stderr(Data)
}

/// How the app authenticates the SSH connection. Boxes come in two flavors
/// (pivot v3): Tailscale SSH (auth at the WireGuard layer — `.none` succeeds)
/// and native sshd/Remote Login (password exactly once during pairing, then the
/// app's own ed25519 key forever after; the password is never stored).
enum BoxAuth: Sendable, Equatable {
    case none(username: String)
    case password(username: String, password: String)
    /// Raw ed25519 key material (`Curve25519.Signing.PrivateKey.rawRepresentation`).
    case privateKey(username: String, privateKeyRaw: Data)

    var username: String {
        switch self {
        case .none(let username), .password(let username, _),
            .privateKey(let username, _):
            return username
        }
    }
}

enum SSHBoxError: Error, Equatable {
    case notConnected
    case unreachable(String)
    /// The server challenged and rejected the offered credentials — for a first
    /// no-credential connect this means "native sshd flavor, ask for a password".
    case authenticationFailed
    /// TOFU pin violation: the box presented a host key that differs from the
    /// pinned one. Pairing hard-fails on this (pivot v3).
    case hostKeyMismatch
    case channelFailed
    case fileNotFound(String)
}

/// A remote command exited non-zero (carries the exit status; any produced
/// output was already streamed).
struct ExecFailure: Error, Equatable {
    let exitCode: Int
}

/// A long-lived remote process with writable stdin — the warm `claude`
/// stream-json session. `output` finishes when the process exits or the
/// channel drops; `close` tears the channel down.
struct ExecChannel: Sendable {
    let output: AsyncThrowingStream<ExecChunk, Error>
    let send: @Sendable (Data) async throws -> Void
    let close: @Sendable () async -> Void
}

/// SSH transport to the paired box. All commands must already be login-shell
/// invocations (`zsh -lc '…'`) — PATH does not resolve on bare exec channels.
/// SFTP paths are relative to the box home directory.
protocol SSHBox: Sendable {
    /// Connect and authenticate. Returns the host key the box presented
    /// (SSH wire-format blob) so the pairing layer can TOFU-pin it. If
    /// `pinnedHostKey` is non-nil and the presented key differs, throws
    /// `SSHBoxError.hostKeyMismatch` before authentication completes.
    @discardableResult
    func connect(address: String, auth: BoxAuth, pinnedHostKey: Data?) async throws -> Data
    var isConnected: Bool { get async }
    func disconnect() async

    /// One-shot exec channel: run to completion, stream output, EOF on exit.
    func exec(_ command: String) async throws -> AsyncThrowingStream<ExecChunk, Error>
    /// Interactive exec channel with writable stdin (the warm claude session).
    func execInteractive(_ command: String) async throws -> ExecChannel

    func sftpRead(path: String) async throws -> Data
    func sftpWrite(path: String, data: Data) async throws
    /// File names (not paths) in a directory.
    func sftpList(directory: String) async throws -> [String]
    /// Create one directory level; succeeds quietly if it already exists.
    func sftpMkdir(path: String) async throws
    func sftpRename(from: String, to: String) async throws
    func sftpRemove(path: String) async throws
}

extension SSHBox {
    /// Run a one-shot command and collect its output — health checks and the
    /// authorized_keys install. Non-zero exit is a result, not a throw.
    func execText(_ command: String) async throws -> (stdout: String, stderr: String, exitCode: Int) {
        var stdout = Data()
        var stderr = Data()
        var exitCode = 0
        do {
            for try await chunk in try await exec(command) {
                switch chunk {
                case .stdout(let data): stdout.append(data)
                case .stderr(let data): stderr.append(data)
                }
            }
        } catch let failure as ExecFailure {
            exitCode = failure.exitCode
        }
        return (
            String(decoding: stdout, as: UTF8.self),
            String(decoding: stderr, as: UTF8.self),
            exitCode)
    }
}

/// Single-quote a string for embedding in a shell command line.
func shellQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Wrap a command in the login shell required for PATH resolution over SSH
/// exec channels (proven on the reference box — pivot v3).
func loginShellCommand(_ command: String) -> String {
    "zsh -lc \(shellQuoted(command))"
}
