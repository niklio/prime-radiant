import SwiftUI

/// The floating input pill (handoff §2.3): "speak or type to the radiant…",
/// mic + send, two ways in as equal citizens. Tapping the text area opens the
/// full-screen chat surface; the mic latches voice with cyan listening rings
/// and a live, editable transcript above the pill.
struct InputPillView: View {
    @Bindable var speech: SpeechInput
    /// Tap on the text area (canvas mode routes to the chat surface).
    var onOpenChat: () -> Void
    var onSend: (String) -> Void
    /// Chat surface docks the same pill but types inline instead of re-opening.
    var typesInline = false
    /// Quiet state line (pivot §3): when set — "the radiant is beyond reach" /
    /// "the radiant rests until the cycle renews" — it occupies the placeholder
    /// slot and the composer disables. No dialogs, ever.
    var statusLine: String?

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if speech.isListening || !speech.transcript.isEmpty {
                transcriptView
            }
            pill
        }
    }

    private var pill: some View {
        HStack(spacing: 12) {
            if let statusLine {
                Text(statusLine)
                    .font(Tokens.Fonts.mono(13))
                    .foregroundStyle(Tokens.Role.secondaryInfo.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("input.status")
            } else if typesInline {
                TextField(
                    "", text: $draft,
                    prompt: Text("speak or type to the radiant…")
                        .foregroundStyle(Tokens.Role.displayText.opacity(0.35))
                )
                .font(Tokens.Fonts.mono(15))
                .foregroundStyle(Tokens.Role.displayText)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(sendDraft)
            } else {
                Text("speak or type to the radiant…")
                    .font(Tokens.Fonts.mono(15))
                    .foregroundStyle(Tokens.Role.displayText.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onOpenChat)
            }

            if statusLine == nil {
                micButton
                sendButton
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            Capsule()
                .fill(Tokens.Palette.void.opacity(0.82))
                .overlay(
                    Capsule().strokeBorder(
                        Tokens.Role.secondaryInfo.opacity(speech.isListening ? 0.6 : 0.18),
                        lineWidth: 1))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("input.pill")
    }

    private var micButton: some View {
        Button(action: { speech.toggle() }) {
            Image(systemName: speech.isListening ? "mic.fill" : "mic")
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(Tokens.Role.listeningAccent)
                .padding(6)
                .background {
                    if speech.isListening {
                        ListeningRings()
                    }
                }
        }
        .accessibilityLabel(speech.isListening ? "release to send" : "speak to the radiant")
    }

    private var sendButton: some View {
        Button(action: sendDraft) {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Tokens.Role.secondaryInfo)
                .padding(8)
                .overlay(Circle().strokeBorder(Tokens.Role.secondaryInfo.opacity(0.5), lineWidth: 1))
        }
        .accessibilityLabel("send")
    }

    /// In-progress transcript above the pill, editable before send (§2.3).
    private var transcriptView: some View {
        TextField("", text: $speech.transcript, axis: .vertical)
            .font(Tokens.Fonts.mono(14))
            .foregroundStyle(Tokens.Role.displayText.opacity(0.9))
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Tokens.Palette.void.opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Tokens.Role.listeningAccent.opacity(0.3), lineWidth: 1)))
    }

    private func sendDraft() {
        // Voice transcript wins if present; otherwise the typed draft.
        let text = speech.transcript.isEmpty ? draft : speech.transcript
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if speech.isListening { speech.stop() }
        speech.transcript = ""
        draft = ""
        onSend(text)
    }
}

/// Cyan concentric rings around the mic while listening (§2.3).
private struct ListeningRings: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { index in
                Circle()
                    .strokeBorder(Tokens.Role.listeningAccent.opacity(0.5), lineWidth: 1)
                    .scaleEffect(animate ? 1.9 + Double(index) * 0.5 : 1)
                    .opacity(animate ? 0 : 0.8)
                    .animation(
                        Motion.isReduced
                            ? nil
                            : .easeOut(duration: 1.4)
                                .repeatForever(autoreverses: false)
                                .delay(Double(index) * 0.45),
                        value: animate)
            }
        }
        .onAppear { animate = true }
    }
}
