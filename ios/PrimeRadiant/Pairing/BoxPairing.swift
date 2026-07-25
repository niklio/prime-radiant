import Crypto
import Foundation
import Observation

/// Pairing is the entirety of auth (pivot v3, replaces the OAuth flow): the
/// user enters the box address (MagicDNS name or 100.x IP), the app connects
/// over SSH, health-checks `claude`, TOFU-pins the host key, and persists the
/// lot in the Keychain. There is no account system, no token refresh, no
/// fallback auth mode — one box, one subscription, one human.

/// What pairing persists (Keychain, after-first-unlock, this device only).
struct PairedBox: Codable, Equatable, Sendable {
    enum Flavor: String, Codable, Sendable {
        /// Tailscale SSH: auth at the WireGuard layer; `.none` credentials.
        case tailscale
        /// Native sshd: the app's own ed25519 key, installed during pairing.
        case key
    }

    var address: String
    var username: String
    var flavor: Flavor
    /// SSH wire-format host key blob, TOFU-pinned at pairing.
    var hostKeyPin: Data
    /// ed25519 private key raw representation; `.key` flavor only.
    var privateKeyRaw: Data?
    /// `ANTHROPIC_API_KEY` was present in the box's login-shell environment at
    /// pairing — turns would silently bill API credits (pivot §5). Warn, allow.
    var apiKeyWarning: Bool

    var auth: BoxAuth {
        switch flavor {
        case .tailscale:
            return .none(username: username)
        case .key:
            return .privateKey(username: username, privateKeyRaw: privateKeyRaw ?? Data())
        }
    }
}

/// The pairing state machine, free of UI so the FakeBox can drive every branch:
/// tailscale flavor, password flavor with key installation, host-key mismatch
/// abort, and the ANTHROPIC_API_KEY warning.
struct PairingFlow: Sendable {
    let box: any SSHBox
    /// ed25519 private key material, injectable for deterministic tests.
    var makeKey: @Sendable () -> Data = {
        Curve25519.Signing.PrivateKey().rawRepresentation
    }

    enum Outcome: Equatable, Sendable {
        case paired(PairedBox)
        /// The box challenged the no-credential connect: native sshd flavor —
        /// ask for the system password (used once, never stored).
        case needsPassword
        /// In the Radiant voice; shown under the pairing field, never a dialog.
        case failed(String)
    }

    func pair(address: String, username: String, password: String?) async -> Outcome {
        // 1. Tailscale flavor first: connect with no credentials at all.
        do {
            let hostKey = try await box.connect(
                address: address, auth: .none(username: username), pinnedHostKey: nil)
            return await finishPairing(
                record: PairedBox(
                    address: address, username: username, flavor: .tailscale,
                    hostKeyPin: hostKey, privateKeyRaw: nil, apiKeyWarning: false))
        } catch SSHBoxError.authenticationFailed {
            // Native sshd flavor — fall through to the password path.
        } catch SSHBoxError.hostKeyMismatch {
            return .failed("another machine answers to this name · pairing refused")
        } catch {
            return .failed("the box is beyond reach")
        }

        // 2. Password flavor: authenticate once, install the app's own key,
        //    prove the key works, and never touch the password again.
        guard let password, !password.isEmpty else { return .needsPassword }
        let hostKey: Data
        do {
            hostKey = try await box.connect(
                address: address,
                auth: .password(username: username, password: password),
                pinnedHostKey: nil)
        } catch SSHBoxError.authenticationFailed {
            return .failed("the box did not accept that password")
        } catch SSHBoxError.hostKeyMismatch {
            return .failed("another machine answers to this name · pairing refused")
        } catch {
            return .failed("the box is beyond reach")
        }

        let privateKeyRaw = makeKey()
        let line = Self.authorizedKeyLine(privateKeyRaw: privateKeyRaw)
        guard let line else { return .failed("the key could not be forged") }
        let install = loginShellCommand(
            "mkdir -p ~/.ssh; chmod 700 ~/.ssh; touch ~/.ssh/authorized_keys; "
                + "chmod 600 ~/.ssh/authorized_keys; "
                + "grep -qxF \(shellQuoted(line)) ~/.ssh/authorized_keys || "
                + "echo \(shellQuoted(line)) >> ~/.ssh/authorized_keys")
        guard let result = try? await box.execText(install), result.exitCode == 0 else {
            await box.disconnect()
            return .failed("the key did not take · try again")
        }

        // Reconnect with the key only — the pin is now enforced, and the
        // password is gone for good.
        await box.disconnect()
        do {
            _ = try await box.connect(
                address: address,
                auth: .privateKey(username: username, privateKeyRaw: privateKeyRaw),
                pinnedHostKey: hostKey)
        } catch SSHBoxError.hostKeyMismatch {
            return .failed("another machine answers to this name · pairing refused")
        } catch {
            return .failed("the key did not take · try again")
        }
        return await finishPairing(
            record: PairedBox(
                address: address, username: username, flavor: .key,
                hostKeyPin: hostKey, privateKeyRaw: privateKeyRaw, apiKeyWarning: false))
    }

    /// Health checks over the live connection (pivot v3): `claude` answers, and
    /// the ANTHROPIC_API_KEY footgun probe.
    private func finishPairing(record: PairedBox) async -> Outcome {
        var record = record
        guard
            let version = try? await box.execText(loginShellCommand("claude --version")),
            version.exitCode == 0,
            !version.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            await box.disconnect()
            return .failed("claude is not answering on the box")
        }

        // grep -c exits 1 on zero matches; the count on stdout is the answer
        // either way (pivot §5: if the key is set, turns would bill API
        // credits — warn in-voice, allow proceeding).
        if let probe = try? await box.execText(
            loginShellCommand("env | grep -c '^ANTHROPIC_API_KEY='")),
            let count = Int(probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
            count > 0 {
            record.apiKeyWarning = true
        }
        return .paired(record)
    }

    /// `authorized_keys` line for the app's generated key:
    /// `ssh-ed25519 <base64 wire blob> prime-radiant`.
    static func authorizedKeyLine(privateKeyRaw: Data) -> String? {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
        else { return nil }
        let publicRaw = key.publicKey.rawRepresentation
        var blob = Data()
        func appendString(_ bytes: Data) {
            var length = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { blob.append(contentsOf: $0) }
            blob.append(bytes)
        }
        appendString(Data("ssh-ed25519".utf8))
        appendString(publicRaw)
        return "ssh-ed25519 \(blob.base64EncodedString()) prime-radiant"
    }
}

/// The paired box at runtime: persistence, the live connection, and
/// reconnect-on-drop. Owned by the app root; everything that talks to the box
/// (chat backend, sync) goes through `ensureConnected`.
@MainActor
@Observable
final class BoxSession {

    private(set) var paired: PairedBox?
    /// Box unreachable → the app opens read-only (pivot §3): canvas renders
    /// from SwiftData, composer and marking disable quietly.
    private(set) var reachable = false

    let box: any SSHBox
    private let keychain: KeychainStore
    private static let recordKey = "box.pairing"

    init(box: any SSHBox = CitadelBox(), keychain: KeychainStore = KeychainStore()) {
        self.box = box
        self.keychain = keychain
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-PRResetPairing") {
                keychain.delete(key: Self.recordKey)
            }
        #endif
        if let data = keychain.load(key: Self.recordKey),
            let record = try? JSONDecoder().decode(PairedBox.self, from: data) {
            paired = record
        }
    }

    var isPaired: Bool { paired != nil }

    /// Persist a fresh pairing (the sheet calls this on `.paired`).
    func adopt(_ record: PairedBox) {
        if let data = try? JSONEncoder().encode(record) {
            try? keychain.save(data, key: Self.recordKey)
        }
        paired = record
        reachable = true
    }

    /// Unpair: forget the box, the key, and the pin; back to ignition.
    func unpair() async {
        keychain.delete(key: Self.recordKey)
        paired = nil
        reachable = false
        await box.disconnect()
    }

    /// Reconnect-on-drop: cheap liveness check before any box operation; flips
    /// `reachable` so the UI can quiet down without dialogs (pivot §3).
    @discardableResult
    func ensureConnected() async -> Bool {
        guard let record = paired else {
            reachable = false
            return false
        }
        if await box.isConnected {
            reachable = true
            return true
        }
        do {
            try await box.connect(
                address: record.address, auth: record.auth, pinnedHostKey: record.hostKeyPin)
            reachable = true
        } catch {
            reachable = false
        }
        return reachable
    }
}
