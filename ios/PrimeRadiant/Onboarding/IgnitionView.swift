import AVFoundation
import SwiftUI

/// The ignition screen (§2.1): a full-screen seamless loop of navigating the
/// radiant in 3D. Over it: the wordmark small and one line — nothing else.
/// Anywhere-tap opens the pairing sheet (pivot v3 — pairing is the entirety
/// of auth). No buttons, no rings, no form furniture: the screen is a window
/// into the instrument, and touching it wakes it.
///
/// Video asset: `IgnitionLoop.mp4` (bundle), produced later by scripting a
/// camera path through a large generated tree in RadiantScene itself and
/// capturing at 2× — HEVC ~30fps, dark-mastered, imperceptible loop point
/// (§2.1). Until it's captured (and always under Reduce Motion / Low Power
/// Mode) the static poster/void stands in.
struct IgnitionView: View {
    @Bindable var session: BoxSession
    /// The persistent world scene: the pairing surface renders over its nebula
    /// void (ux-update §1 — the same void full-screen, no sheet chrome).
    var world: RadiantScene?
    @State private var pairing: PairingController?

    var body: some View {
        ZStack {
            Tokens.Role.background.ignoresSafeArea()

            if Motion.ignitionVideoAllowed, let url = Self.loopURL {
                LoopingVideoView(url: url)
                    .ignoresSafeArea()
            } else {
                // Poster frame: the "IgnitionPoster" imageset ships a still from
                // the same capture; the void alone carries it until then.
                Image("IgnitionPoster")
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .opacity(0.9)
            }

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

    private static var loopURL: URL? {
        Bundle.main.url(forResource: "IgnitionLoop", withExtension: "mp4")
    }
}

/// AVPlayerLooper-backed seamless loop, muted, aspect-fill.
private struct LoopingVideoView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: item)
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        player.play()
        return view
    }

    func updateUIView(_ view: PlayerContainerView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var looper: AVPlayerLooper?
    }

    final class PlayerContainerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
