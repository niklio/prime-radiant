import SwiftUI

/// Settings surface (pivot v3 + ux-update §1): the paired box, the quiet
/// *re-provision* action (provisioning re-runs are the whole upgrade story —
/// server/README), and Unpair. Pairing itself lives on the full-screen staged
/// flow (PairingFlowView); this is the only place it can be redone or undone.
struct BoxSettingsView: View {
    @Bindable var session: BoxSession
    /// Present the provisioning stage lines over the void (re-provision).
    var onReprovision: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("the box")
                .font(Tokens.Fonts.display(26))
                .foregroundStyle(Tokens.Role.displayText)

            if let paired = session.paired {
                row("address", paired.address)
                if !paired.username.isEmpty {
                    row("user", paired.username)
                }
                row("auth", authLabel(paired.flavor))
                if let gateway = paired.gatewayAddress {
                    row("gateway", gateway)
                }
                row("state", session.reachable ? "reachable" : "beyond reach")
                if paired.apiKeyWarning {
                    Text("api key present at pairing · turns may bill credits")
                        .font(Tokens.Fonts.mono(11))
                        .foregroundStyle(Tokens.Role.terminalAdverse.opacity(0.8))
                }

                // Quiet update mechanism: re-running the idempotent bundle
                // replaces server.mjs, keeps config/token/data (1c2 again).
                if paired.flavor != .gateway {
                    Button {
                        dismiss()
                        onReprovision()
                    } label: {
                        Text("re-provision")
                            .font(Tokens.Fonts.mono(14, medium: true))
                            .tracking(Tokens.Fonts.labelTracking)
                            .foregroundStyle(Tokens.Role.secondaryInfo)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .overlay(
                                Capsule().strokeBorder(
                                    Tokens.Role.secondaryInfo.opacity(0.4), lineWidth: 1))
                    }
                    .padding(.top, 16)
                    .accessibilityIdentifier("settings.reprovision")
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
                .padding(.top, paired.flavor == .gateway ? 16 : 4)
                .accessibilityIdentifier("settings.unpair")
            }

            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.Role.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func authLabel(_ flavor: PairedBox.Flavor) -> String {
        switch flavor {
        case .tailscale: return "tailscale"
        case .key: return "key"
        case .gateway: return "code"
        }
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
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
