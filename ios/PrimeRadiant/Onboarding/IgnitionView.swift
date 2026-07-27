import SwiftUI

/// The ignition screen (§2.1, as amended by the owner 2026-07-27): the live
/// nebula void with a single waiting node — the same background the pairing
/// screens carry — instead of the originally-planned flythrough video. One
/// wordmark, one line, anywhere-tap begins pairing (pivot v3 — pairing is
/// the entirety of auth). No buttons, no form furniture: the screen is a
/// window into the instrument, and touching it wakes it.
struct IgnitionView: View {
    @Bindable var session: BoxSession
    /// The persistent world scene renders the nebula void behind everything
    /// (ux-update §1 — the same void full-screen, no sheet chrome).
    var world: RadiantScene?
    @State private var pairing: PairingController?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Tokens.Role.background.ignoresSafeArea()

                if let world {
                    // Interactive so the render delegate drives advance() (the
                    // nebula breathes); hit-testing off — this view owns touch.
                    CanvasView(radiant: world, interactive: true)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                // The waiting node sits where the pairing flow keeps it, so the
                // tap transition holds the dot still while the field arrives.
                PairingNodeView(style: .waiting)
                    .position(
                        x: geometry.size.width / 2,
                        y: geometry.size.height * 0.354)

                VStack(spacing: 18) {
                    Spacer()
                    Text("PRIME RADIANT")
                        .font(Tokens.Fonts.mono(14, medium: true))
                        .tracking(6)
                        .foregroundStyle(Tokens.Role.displayText)
                        .accessibilityIdentifier("ignition.wordmark")
                    Text("touch to begin")
                        .font(Tokens.Fonts.mono(12))
                        .tracking(1.5)
                        .foregroundStyle(Tokens.Role.displayText.opacity(0.6))
                    Spacer().frame(height: 90)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            beginPairing()
        }
        #if DEBUG
            // `-PRDebugPairing` presents the pairing surface immediately;
            // `-PRDebugPairingState=<address|unreachable|credentials|
            // provisioning|code|paired>` renders each state deterministically
            // with representative content (mock capture loop).
            .onAppear {
                let args = ProcessInfo.processInfo.arguments
                if args.contains("-PRDebugPairing") {
                    beginPairing()
                } else if let state = PairingController.debugStateArgument() {
                    beginPairing(debugState: state)
                }
            }
        #endif
        .fullScreenCover(item: $pairing) { controller in
            PairingFlowView(
                controller: controller,
                radiant: world,
                frozen: Self.debugFrozen)
        }
        .statusBarHidden()
    }

    private static var debugFrozen: Bool {
        #if DEBUG
            return PairingController.debugStateArgument() != nil
        #else
            return false
        #endif
    }

    private func beginPairing(debugState: String? = nil) {
        let controller = PairingController(box: session.box) { record in
            session.adopt(record)
            pairing = nil
        }
        #if DEBUG
            if let debugState {
                controller.applyDebugState(debugState)
            }
        #endif
        pairing = controller
    }
}
