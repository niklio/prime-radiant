import AVFoundation
import SwiftUI

/// The ignition screen (§2.1): a full-screen seamless loop of navigating the
/// radiant in 3D. Over it: the wordmark small and one line — nothing else.
/// Anywhere-tap starts OAuth. No buttons, no rings, no form furniture: the
/// screen is a window into the instrument, and touching it wakes it.
///
/// Video asset: `IgnitionLoop.mp4` (bundle), produced later by scripting a
/// camera path through a large generated tree in RadiantScene itself and
/// capturing at 2× — HEVC ~30fps, dark-mastered, imperceptible loop point
/// (§2.1). Until it's captured (and always under Reduce Motion / Low Power
/// Mode) the static poster/void stands in.
struct IgnitionView: View {
    @Bindable var auth: OpenAIAuth

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
                Text(line)
                    .font(Tokens.Fonts.mono(12))
                    .tracking(1.5)
                    .foregroundStyle(Tokens.Role.displayText.opacity(0.6))
                Spacer().frame(height: 90)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard auth.state != .linking else { return }
            Task { await auth.signIn() }
        }
        .statusBarHidden()
    }

    /// If OAuth is unavailable, the app says so here and waits (§2.1) — there is
    /// no fallback auth mode.
    private var line: String {
        switch auth.state {
        case .linking:
            return "linking…"
        case .unavailable(let message):
            return message
        default:
            return "touch to begin · sign in with ChatGPT"
        }
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
