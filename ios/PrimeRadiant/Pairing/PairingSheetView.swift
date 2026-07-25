import SwiftUI
import UIKit

/// The pairing sheet (pivot v3): one field — the box address (MagicDNS name or
/// 100.x IP). Username defaults to the common case; a password field appears
/// only if the box challenges. Sparse, lowercase, no form furniture.
struct PairingSheetView: View {
    @Bindable var session: BoxSession
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var username = PairingSheetView.defaultUsername()
    @State private var password = ""
    @State private var needsPassword = false
    @State private var working = false
    @State private var line: String?
    /// Paired but the ANTHROPIC_API_KEY warning fired — one confirmation.
    @State private var pendingWarned: PairedBox?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("reach your box")
                .font(Tokens.Fonts.display(26))
                .foregroundStyle(Tokens.Role.displayText)

            if let warned = pendingWarned {
                warningView(warned)
            } else {
                fields
            }

            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.Role.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var fields: some View {
        field("address of the box · magicdns or 100.x", text: $address, identifier: "pairing.address")
            .keyboardType(.URL)
        field("username on the box", text: $username, identifier: "pairing.username")
        if needsPassword {
            SecureField(
                "", text: $password,
                prompt: prompt("system password · used once, never kept")
            )
            .fieldStyle()
            .accessibilityIdentifier("pairing.password")
        }

        if let line {
            Text(line)
                .font(Tokens.Fonts.mono(12))
                .foregroundStyle(Tokens.Role.terminalAdverse.opacity(0.9))
        }

        Button(action: pair) {
            Text(working ? "reaching…" : "pair")
                .font(Tokens.Fonts.mono(14, medium: true))
                .tracking(Tokens.Fonts.labelTracking)
                .foregroundStyle(Tokens.Palette.void)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Capsule().fill(Tokens.Role.displayText.opacity(working ? 0.4 : 1)))
        }
        .disabled(working || address.trimmingCharacters(in: .whitespaces).isEmpty)
        .accessibilityIdentifier("pairing.pair")
    }

    /// Pivot §5: an API key in the box's login-shell environment means turns
    /// would silently bill API credits instead of the plan. Warn, allow.
    private func warningView(_ record: PairedBox) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("an api key sits in the box's air — turns would bill credits, not the plan")
                .font(Tokens.Fonts.mono(13))
                .foregroundStyle(Tokens.Role.terminalAdverse.opacity(0.9))
            Text("unset ANTHROPIC_API_KEY on the box to ride the subscription")
                .font(Tokens.Fonts.mono(12))
                .foregroundStyle(Tokens.Role.secondaryInfo)
            Button {
                session.adopt(record)
                dismiss()
            } label: {
                Text("proceed anyway")
                    .font(Tokens.Fonts.mono(14, medium: true))
                    .foregroundStyle(Tokens.Palette.void)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Tokens.Role.displayText))
            }
            .accessibilityIdentifier("pairing.proceed")
        }
    }

    private func pair() {
        guard !working else { return }
        working = true
        line = nil
        let flow = PairingFlow(box: session.box)
        let address = address.trimmingCharacters(in: .whitespaces)
        let username = username.trimmingCharacters(in: .whitespaces)
        let password = needsPassword ? password : nil
        Task {
            let outcome = await flow.pair(
                address: address, username: username, password: password)
            working = false
            switch outcome {
            case .paired(let record) where record.apiKeyWarning:
                pendingWarned = record
            case .paired(let record):
                session.adopt(record)
                dismiss()
            case .needsPassword:
                needsPassword = true
                line = "the box asks for its system password"
            case .failed(let message):
                line = message
            }
        }
    }

    private func field(
        _ promptText: String, text: Binding<String>, identifier: String
    ) -> some View {
        TextField("", text: text, prompt: prompt(promptText))
            .fieldStyle()
            .accessibilityIdentifier(identifier)
    }

    private func prompt(_ text: String) -> Text {
        Text(text).foregroundStyle(Tokens.Role.displayText.opacity(0.35))
    }

    /// The common case for a personal Mac: the owner's short name, guessed from
    /// the device name ("Nik's iPhone" → "nik"). Editable, of course.
    static func defaultUsername() -> String {
        let name = UIDevice.current.name
        let first = name.split(separator: " ").first.map(String.init) ?? ""
        let stem = first.split(separator: "'").first.map(String.init) ?? first
        let letters = stem.lowercased().filter { $0.isLetter }
        return letters
    }
}

private extension View {
    func fieldStyle() -> some View {
        self
            .font(Tokens.Fonts.mono(15))
            .foregroundStyle(Tokens.Role.displayText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Tokens.Role.secondaryInfo.opacity(0.3), lineWidth: 1))
    }
}

/// Settings surface (pivot v3): the paired box and Unpair. Replaces the OpenAI
/// account UI in its entirety.
struct BoxSettingsView: View {
    @Bindable var session: BoxSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("the box")
                .font(Tokens.Fonts.display(26))
                .foregroundStyle(Tokens.Role.displayText)

            if let paired = session.paired {
                row("address", paired.address)
                row("user", paired.username)
                row("auth", paired.flavor == .tailscale ? "tailscale" : "key")
                row("state", session.reachable ? "reachable" : "beyond reach")
                if paired.apiKeyWarning {
                    Text("api key present at pairing · turns may bill credits")
                        .font(Tokens.Fonts.mono(11))
                        .foregroundStyle(Tokens.Role.terminalAdverse.opacity(0.8))
                }

                Button {
                    Task {
                        await session.unpair()
                        dismiss()
                    }
                } label: {
                    Text("unpair")
                        .font(Tokens.Fonts.mono(14, medium: true))
                        .tracking(Tokens.Fonts.labelTracking)
                        .foregroundStyle(Tokens.Role.terminalAdverse)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .overlay(
                            Capsule().strokeBorder(
                                Tokens.Role.terminalAdverse.opacity(0.5), lineWidth: 1))
                }
                .padding(.top, 16)
                .accessibilityIdentifier("settings.unpair")
            }

            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.Role.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(Tokens.Fonts.mono(12))
                .foregroundStyle(Tokens.Role.secondaryInfo)
            Spacer()
            Text(value)
                .font(Tokens.Fonts.mono(12))
                .foregroundStyle(Tokens.Role.displayText)
        }
    }
}
