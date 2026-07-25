import SwiftUI

/// The voice listening surface (mock 9): while the radiant listens the capsule
/// gives way to a large circular mic centered low, two concentric expanding
/// rings, a thin cyan waveform, and the live transcript in curly quotes with a
/// leading ellipsis. The tree brightens ~15% behind it (RadiantScene). Tap the
/// mic to stop; the transcript hands back to the capsule, editable before send.
struct VoiceListeningView: View {
    @Bindable var speech: SpeechInput

    var body: some View {
        VStack(spacing: 0) {
            micCircle
            waveform
                .padding(.top, 56)
            transcriptLine
                .padding(.top, 22)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice.listening")
    }

    private var micCircle: some View {
        Button(action: { speech.toggle() }) {
            ZStack {
                PulseRings()
                Circle()
                    .strokeBorder(Tokens.Role.listeningAccent.opacity(0.65), lineWidth: 1.2)
                    .frame(width: 56, height: 56)
                Image(systemName: "mic")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Tokens.Role.listeningAccent)
            }
        }
        .accessibilityLabel("release to send")
    }

    private var waveform: some View {
        WaveformShapeView()
            .frame(width: 250, height: 22)
    }

    private var transcriptLine: some View {
        // Leading-ellipsis live transcript, curly quotes (mock 9):
        // “…she came back at forty, and honestly the timeline—”
        Text("\u{201C}…\(speech.transcript)—\u{201D}")
            .font(Tokens.Fonts.mono(10))
            .tracking(0.4)
            .foregroundStyle(Tokens.Role.displayText.opacity(0.75))
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .accessibilityIdentifier("voice.transcript")
    }
}

/// Two concentric rings expanding outward on the voice pulse period (~1.6s).
private struct PulseRings: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { index in
                Circle()
                    .strokeBorder(
                        Tokens.Role.listeningAccent.opacity(0.4 - Double(index) * 0.12),
                        lineWidth: 1)
                    .frame(width: 56, height: 56)
                    .scaleEffect(ringScale(index))
                    .opacity(Motion.isReduced ? 1 : (animate ? 0 : 0.9))
                    .animation(
                        Motion.isReduced
                            ? nil
                            : .easeOut(duration: Tokens.Motion.voicePulsePeriodSeconds)
                                .repeatForever(autoreverses: false)
                                .delay(
                                    Double(index) * Tokens.Motion.voicePulsePeriodSeconds / 2),
                        value: animate)
            }
        }
        .onAppear { animate = true }
    }

    private func ringScale(_ index: Int) -> Double {
        if Motion.isReduced { return 1.35 + Double(index) * 0.45 }
        return animate ? 2.1 : 1.1
    }
}

/// Thin cyan waveform polyline. Live-ish: gentle sinusoid mixture drifting with
/// time; static under Reduce Motion.
private struct WaveformShapeView: View {
    var body: some View {
        if Motion.isReduced {
            WaveformShape(phase: 0)
                .stroke(Tokens.Role.listeningAccent.opacity(0.8), lineWidth: 1)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                WaveformShape(phase: context.date.timeIntervalSinceReferenceDate)
                    .stroke(Tokens.Role.listeningAccent.opacity(0.8), lineWidth: 1)
            }
        }
    }
}

private struct WaveformShape: Shape {
    var phase: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let count = 48
        for index in 0...count {
            let f = Double(index) / Double(count)
            let x = rect.minX + rect.width * CGFloat(f)
            // Mixed frequencies so peaks read organic, tapered at both edges.
            let envelope = sin(f * .pi)
            let wave =
                sin(f * 26 + phase * 5.5) * 0.5
                + sin(f * 11 - phase * 3.2) * 0.32
                + sin(f * 47 + phase * 8.1) * 0.18
            let y = rect.midY - CGFloat(wave * envelope) * rect.height * 0.48
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}
