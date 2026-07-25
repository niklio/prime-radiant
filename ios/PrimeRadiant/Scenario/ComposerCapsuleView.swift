import PrimeRadiantCore
import SwiftUI

/// The node context carried by the capsule when a node is selected (mock 5/6):
/// serif title, amber `EV ≈ …` line, and the ridge data behind the ▸/▾ toggle.
struct CapsuleNodeContext {
    var title: String
    var evLine: String?
    var distribution: [DistributionPoint]
    var mean: Double?
    var unit: PayoffUnit
    var caption: String
}

/// The one composer capsule (mocks 4/5/6/8): a rounded rect with a thin amber
/// hairline on a dark translucent fill. Idle it is just the composer (placeholder
/// `describe the decision…`, mic, filled cyan send disc). With a node selected it
/// gains a title row (serif title · amber EV · tiny ▸/▾ toggle) over a hairline
/// divider; expanded it carries the luminous ridge between them. The placeholder
/// is state, never instruction (notes §4).
struct ComposerCapsuleView: View {
    var context: CapsuleNodeContext?
    var isExpanded: Binding<Bool>?
    @Bindable var speech: SpeechInput
    var placeholder: String
    /// Tap on the text area (canvas mode routes to the chat surface).
    var onOpenChat: () -> Void
    var onSend: (String) -> Void
    /// Chat surface docks the same capsule but types inline instead of re-opening.
    var typesInline = false
    /// Quiet state line (pivot §3): occupies the placeholder slot; composer disables.
    var statusLine: String?

    @State private var draft = ""
    @FocusState private var focused: Bool

    private var expanded: Bool { isExpanded?.wrappedValue ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Voice transcript stays editable before send (§2.3) once the
            // listening surface hands back.
            if !speech.isListening, !speech.transcript.isEmpty {
                transcriptView
            }
            capsule
        }
    }

    private var capsule: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let context {
                titleRow(context)
                if expanded {
                    DistributionRidgeView(
                        points: context.distribution,
                        mean: context.mean,
                        unit: context.unit,
                        caption: context.caption)
                        .padding(.horizontal, 20)
                        .padding(.top, 2)
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }
                Divider()
                    .overlay(Tokens.Role.displayText.opacity(0.22))
                    .padding(.horizontal, 18)
            }
            composerRow(tall: context == nil)
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Tokens.Palette.void.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Tokens.Role.edgeNeutral.opacity(0.24), lineWidth: 1))
        )
        .animation(
            Motion.isReduced
                ? nil
                : .easeOut(
                    duration: expanded
                        ? Tokens.Motion.ridgeExpandSeconds : Tokens.Motion.ridgeCollapseSeconds),
            value: expanded)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("canvas.capsule")
    }

    // MARK: - Title row (mock 5): serif title · EV ≈ +$12k · ▸/▾

    private func titleRow(_ context: CapsuleNodeContext) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(context.title)
                .font(Tokens.Fonts.display(20))
                .foregroundStyle(Tokens.Role.displayText)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .layoutPriority(1)
                .accessibilityIdentifier("capsule.title")

            Spacer(minLength: 8)

            if let evLine = context.evLine {
                Button {
                    toggleRidge()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(evLine)
                            .font(Tokens.Fonts.mono(13))
                            .tracking(0.5)
                            .foregroundStyle(Tokens.Role.selectedPath)
                            .fixedSize()
                            .accessibilityIdentifier("capsule.ev")
                        Text(expanded ? "▾" : "▸")
                            .font(Tokens.Fonts.mono(9))
                            .foregroundStyle(
                                expanded
                                    ? Tokens.Role.secondaryInfo
                                    : Tokens.Role.displayText.opacity(0.45))
                    }
                }
                .disabled(context.distribution.isEmpty)
                .accessibilityIdentifier("capsule.distribution.toggle")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func toggleRidge() {
        guard let isExpanded else { return }
        if Motion.isReduced {
            isExpanded.wrappedValue.toggle()
            return
        }
        let opening = !isExpanded.wrappedValue
        withAnimation(
            .easeOut(
                duration: opening
                    ? Tokens.Motion.ridgeExpandSeconds : Tokens.Motion.ridgeCollapseSeconds)
        ) {
            isExpanded.wrappedValue.toggle()
        }
    }

    // MARK: - Composer row (mocks 4/8: tall, icons at lower right; mock 5: one line)

    @ViewBuilder
    private func composerRow(tall: Bool) -> some View {
        if tall {
            VStack(alignment: .leading, spacing: 10) {
                textArea
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 14) {
                    Spacer()
                    if statusLine == nil {
                        micButton
                        sendButton
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)
        } else {
            HStack(spacing: 14) {
                textArea
                    .frame(maxWidth: .infinity, alignment: .leading)
                if statusLine == nil {
                    micButton
                    sendButton
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var textArea: some View {
        if let statusLine {
            Text(statusLine)
                .font(Tokens.Fonts.mono(12))
                .tracking(0.8)
                .foregroundStyle(Tokens.Role.secondaryInfo.opacity(0.7))
                .accessibilityIdentifier("input.status")
        } else if typesInline {
            TextField(
                "", text: $draft,
                prompt: Text(placeholder)
                    .foregroundStyle(Tokens.Role.displayText.opacity(0.45))
            )
            .font(Tokens.Fonts.mono(12))
            .foregroundStyle(Tokens.Role.displayText)
            .focused($focused)
            .submitLabel(.send)
            .onSubmit(sendDraft)
            .accessibilityIdentifier("capsule.composer")
        } else {
            Text(placeholder)
                .font(Tokens.Fonts.mono(12))
                .tracking(0.8)
                .foregroundStyle(Tokens.Role.displayText.opacity(0.45))
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpenChat)
                .accessibilityIdentifier("capsule.composer")
        }
    }

    /// Mic and send are one family (notes §4): thin-stroke mic, filled cyan
    /// disc (r12) with a void-colored arrow.
    private var micButton: some View {
        Button(action: { speech.toggle() }) {
            Image(systemName: speech.isListening ? "mic.fill" : "mic")
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(Tokens.Role.listeningAccent)
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
            ZStack {
                Circle()
                    .fill(Tokens.Role.secondaryInfo.opacity(hasContent ? 1 : 0.88))
                    .frame(width: 24, height: 24)
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.Palette.void)
            }
        }
        .accessibilityLabel("send")
    }

    private var hasContent: Bool {
        !draft.isEmpty || !speech.transcript.isEmpty
    }

    /// In-progress transcript above the capsule, editable before send (§2.3).
    private var transcriptView: some View {
        TextField("", text: $speech.transcript, axis: .vertical)
            .font(Tokens.Fonts.mono(13))
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

/// Cyan concentric rings around the mic while listening in the chat surface
/// (the canvas hands off to the full listening surface instead).
struct ListeningRings: View {
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
