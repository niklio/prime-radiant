import Crypto
import Foundation

@preconcurrency import Citadel
@preconcurrency import NIOCore
@preconcurrency import NIOSSH

/// Citadel-backed `SSHBox` (pivot v3). One `SSHClient` per box, guarded by the
/// actor; exec channels and SFTP subchannels multiplex over the single SSH
/// connection. Reconnect-on-drop lives one layer up in `BoxSession`, where the
/// auth flavor and the host-key pin are known.
actor CitadelBox: SSHBox {

    private var client: SSHClient?

    var isConnected: Bool {
        client?.isConnected ?? false
    }

    // MARK: - Connect / disconnect

    @discardableResult
    func connect(address: String, auth: BoxAuth, pinnedHostKey: Data?) async throws -> Data {
        await disconnect()

        let presented = PresentedHostKey()
        let method: SSHAuthenticationMethod
        switch auth {
        case .none(let username):
            method = .custom(NoneAuthDelegate(username: username))
        case .password(let username, let password):
            method = .passwordBased(username: username, password: password)
        case .privateKey(let username, let raw):
            let key: Curve25519.Signing.PrivateKey
            do {
                key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
            } catch {
                throw SSHBoxError.authenticationFailed
            }
            method = .ed25519(username: username, privateKey: key)
        }

        do {
            client = try await SSHClient.connect(
                host: address,
                authenticationMethod: method,
                hostKeyValidator: .custom(
                    PinningHostKeyValidator(pinned: pinnedHostKey, presented: presented)),
                reconnect: .never,
                connectTimeout: .seconds(10))
        } catch let error as SSHBoxError {
            throw error
        } catch {
            if presented.mismatch {
                throw SSHBoxError.hostKeyMismatch
            }
            if error is Citadel.AuthenticationFailed || error is SSHClientError {
                throw SSHBoxError.authenticationFailed
            }
            throw SSHBoxError.unreachable(String(describing: error))
        }
        guard let hostKey = presented.data else {
            throw SSHBoxError.unreachable("no host key presented")
        }
        return hostKey
    }

    func disconnect() async {
        if let client {
            try? await client.close()
        }
        client = nil
    }

    private func activeClient() throws -> SSHClient {
        guard let client, client.isConnected else { throw SSHBoxError.notConnected }
        return client
    }

    // MARK: - Exec

    func exec(_ command: String) async throws -> AsyncThrowingStream<ExecChunk, Error> {
        let client = try activeClient()
        let source = try await client.executeCommandStream(command)
        let (stream, continuation) = AsyncThrowingStream<ExecChunk, Error>.makeStream()
        let task = Task {
            do {
                for try await chunk in source {
                    switch chunk {
                    case .stdout(let buffer):
                        continuation.yield(.stdout(Data(buffer.readableBytesView)))
                    case .stderr(let buffer):
                        continuation.yield(.stderr(Data(buffer.readableBytesView)))
                    }
                }
                continuation.finish()
            } catch let failed as SSHClient.CommandFailed {
                continuation.finish(throwing: ExecFailure(exitCode: failed.exitCode))
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func execInteractive(_ command: String) async throws -> ExecChannel {
        let client = try activeClient()
        let (output, outputContinuation) = AsyncThrowingStream<ExecChunk, Error>.makeStream()
        let (stdin, stdinContinuation) = AsyncStream<StdinEvent>.makeStream()
        let state = InteractiveState()

        let task = Task {
            do {
                // A shell channel (no PTY: no echo, no CRLF mangling, separate
                // stderr). sshd answers a shell request with the user's *login*
                // shell; `exec` then replaces it with the command so all further
                // stdin lands on the remote process.
                try await client.withTTY { inbound, outbound in
                    try await outbound.write(ByteBuffer(string: "exec \(command)\n"))
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await chunk in inbound {
                                switch chunk {
                                case .stdout(let buffer):
                                    outputContinuation.yield(.stdout(Data(buffer.readableBytesView)))
                                case .stderr(let buffer):
                                    outputContinuation.yield(.stderr(Data(buffer.readableBytesView)))
                                }
                            }
                        }
                        group.addTask {
                            for await event in stdin {
                                switch event {
                                case .data(let data):
                                    try await outbound.write(ByteBuffer(bytes: data))
                                case .close:
                                    return
                                }
                            }
                        }
                        // First side to finish (remote EOF or local close) wins;
                        // withTTY closes the channel on return.
                        try await group.next()
                        group.cancelAll()
                    }
                }
                state.markClosed()
                outputContinuation.finish()
            } catch let failed as SSHClient.CommandFailed {
                state.markClosed()
                outputContinuation.finish(throwing: ExecFailure(exitCode: failed.exitCode))
            } catch {
                state.markClosed()
                outputContinuation.finish(throwing: error)
            }
        }

        return ExecChannel(
            output: output,
            send: { data in
                guard state.isOpen else { throw SSHBoxError.channelFailed }
                stdinContinuation.yield(.data(data))
            },
            close: {
                state.markClosed()
                stdinContinuation.yield(.close)
                stdinContinuation.finish()
                // Give the channel a moment to unwind, then make sure.
                task.cancel()
            })
    }

    private enum StdinEvent: Sendable {
        case data(Data)
        case close
    }

    // MARK: - SFTP (paths relative to the box home directory)

    private func withSFTP<R: Sendable>(
        _ body: @escaping @Sendable (SFTPClient) async throws -> R
    ) async throws -> R {
        let client = try activeClient()
        return try await client.withSFTP { sftp in
            try await body(sftp)
        }
    }

    func sftpRead(path: String) async throws -> Data {
        try await withSFTP { sftp in
            let file: SFTPFile
            do {
                file = try await sftp.openFile(filePath: path, flags: .read)
            } catch {
                throw SSHBoxError.fileNotFound(path)
            }
            do {
                let buffer = try await file.readAll()
                try await file.close()
                return Data(buffer.readableBytesView)
            } catch {
                try? await file.close()
                throw error
            }
        }
    }

    func sftpWrite(path: String, data: Data) async throws {
        try await withSFTP { sftp in
            try await sftp.withFile(
                filePath: path, flags: [.write, .create, .truncate]
            ) { file in
                try await file.write(ByteBuffer(bytes: data), at: 0)
            }
        }
    }

    func sftpList(directory: String) async throws -> [String] {
        try await withSFTP { sftp in
            let names = try await sftp.listDirectory(atPath: directory)
            return names
                .flatMap { $0.components.map(\.filename) }
                .filter { $0 != "." && $0 != ".." }
        }
    }

    func sftpMkdir(path: String) async throws {
        try await withSFTP { sftp in
            do {
                try await sftp.createDirectory(atPath: path)
            } catch {
                // mkdir -p semantics: fine if it already exists, rethrow otherwise.
                do {
                    _ = try await sftp.getAttributes(at: path)
                } catch {
                    throw SSHBoxError.channelFailed
                }
            }
        }
    }

    func sftpRename(from: String, to: String) async throws {
        try await withSFTP { sftp in
            try await sftp.rename(at: from, to: to)
        }
    }

    func sftpRemove(path: String) async throws {
        try await withSFTP { sftp in
            try await sftp.remove(at: path)
        }
    }
}

/// Records the host key the server presented during the handshake (thread-safe;
/// the validator runs on the NIO event loop).
private final class PresentedHostKey: @unchecked Sendable {
    private let lock = NSLock()
    private var _data: Data?
    private var _mismatch = false

    var data: Data? {
        lock.withLock { _data }
    }
    var mismatch: Bool {
        lock.withLock { _mismatch }
    }
    func record(_ data: Data) {
        lock.withLock { _data = data }
    }
    func markMismatch() {
        lock.withLock { _mismatch = true }
    }
}

/// TOFU pinning (pivot v3): first connect records the presented key for the
/// pairing layer to persist; later connects compare against the Keychain pin
/// and hard-fail the handshake on mismatch.
private final class PinningHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    private let pinned: Data?
    private let presented: PresentedHostKey

    init(pinned: Data?, presented: PresentedHostKey) {
        self.pinned = pinned
        self.presented = presented
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>
    ) {
        var buffer = ByteBuffer()
        _ = hostKey.write(to: &buffer)
        let data = Data(buffer.readableBytesView)
        presented.record(data)
        if let pinned, pinned != data {
            presented.markMismatch()
            validationCompletePromise.fail(SSHBoxError.hostKeyMismatch)
        } else {
            validationCompletePromise.succeed(())
        }
    }
}

/// Offers `none` authentication once — Tailscale SSH accepts it (auth already
/// happened at the WireGuard layer); native sshd rejects it, which surfaces as
/// `authenticationFailed` and routes pairing to the password path.
private final class NoneAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private var offered = false  // event-loop confined

    init(username: String) {
        self.username = username
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered else {
            nextChallengePromise.fail(SSHBoxError.authenticationFailed)
            return
        }
        offered = true
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .none))
    }
}

/// Interactive-channel liveness flag shared between the actor and the channel
/// closures (lock-protected; touched from multiple tasks).
private final class InteractiveState: @unchecked Sendable {
    private let lock = NSLock()
    private var _open = true

    var isOpen: Bool {
        lock.withLock { _open }
    }
    func markClosed() {
        lock.withLock { _open = false }
    }
}
