import PrimeRadiantCore
import SwiftUI

/// The full-screen chat surface (§2.3, mock 8): its own screen, never a half
/// sheet. `‹ CANVAS` returns; the scenario title sits centered in serif. User
/// messages ride right-aligned in dark rounded bubbles wrapped in curly quotes;
/// assistant prose is plain left-aligned parchment mono, no bubble. A patch turn
/// shows the `◈ the futures reorganize…` status line while the ghost tree
/// behind brightens 15% → 35%. The composer capsule docks at the bottom
/// (placeholder `…` mid-thread).
struct ChatSurfaceView: View {
    @Bindable var store: ScenarioStore
    @State private var speech = SpeechInput()

    var body: some View {
        ZStack(alignment: .bottom) {
            Tokens.Role.background.ignoresSafeArea()

            // Ghosted tree ambience; brightens while a patch reorganizes
            // (tokens layout.chatSurfaceTreeOpacity / chatSurfacePatchTreeOpacity).
            CanvasView(radiant: store.radiant, interactive: false)
                .opacity(
                    store.reorganizing
                        ? Tokens.Layout.chatSurfacePatchTreeOpacity
                        : Tokens.Layout.chatSurfaceTreeOpacity)
                .animation(.easeInOut(duration: 0.4), value: store.reorganizing)
                .allowsHitTesting(false)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                messageList
                ComposerCapsuleView(
                    context: nil,
                    isExpanded: nil,
                    speech: speech,
                    placeholder: "…",
                    onOpenChat: {},
                    onSend: { store.send(text: $0) },
                    typesInline: true,
                    statusLine: store.composerStatusLine)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .statusBarHidden()
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { value in
                if value.translation.height > 80 { store.closeChat() }
            })
    }

    private var topBar: some View {
        ZStack {
            Text(store.scenario.title)
                .font(Tokens.Fonts.display(15))
                .foregroundStyle(Tokens.Role.displayText)
                .lineLimit(1)
                .padding(.horizontal, 90)
            HStack {
                Button(action: { store.closeChat() }) {
                    Text("‹ CANVAS")
                        .font(Tokens.Fonts.mono(10))
                        .tracking(1.8)
                        .foregroundStyle(Tokens.Role.secondaryInfo)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var messageList: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    messageStack(minHeight: geometry.size.height)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: store.streamingSay) {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }
        }
    }

    /// Top-aligned while the thread is short (mock 8); bottom-anchored once it
    /// overflows (streaming stays pinned).
    private func messageStack(minHeight: CGFloat) -> some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            // Node-anchored context, shown once when opened from a node (§2.3 #4).
            if let focusedId = store.focusedNodeId,
                let node = Tree.find(store.scenario.tree, id: focusedId) {
                Text("· about \(node.label) ·")
                    .font(Tokens.Fonts.mono(11))
                    .foregroundStyle(Tokens.Role.secondaryInfo.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            ForEach(Array(store.scenario.transcript.enumerated()), id: \.offset) { _, message in
                MessageRow(message: message)
            }

            if store.isStreaming {
                StreamingRow(text: store.streamingSay)
                    .id("streaming")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(minHeight: minHeight, alignment: .top)
    }
}

private struct MessageRow: View {
    let message: Message

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 14) {
            if message.role == .user {
                // Curly typographic quotes around user speech (mock 8).
                Text("\u{201C}\(message.content)\u{201D}")
                    .font(Tokens.Fonts.mono(12))
                    .foregroundStyle(Tokens.Role.displayText.opacity(0.95))
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Tokens.Role.displayText.opacity(0.07)))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text(message.content)
                    .font(Tokens.Fonts.mono(13))
                    .foregroundStyle(Tokens.Role.displayText.opacity(0.9))
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if message.patchApplied != nil {
                    PatchStatusLine()
                }
            }
        }
    }
}

/// `◈ the futures reorganize…` — the patch status line (mock 8): small diamond,
/// mono, letterspaced, whisper cyan.
private struct PatchStatusLine: View {
    var body: some View {
        Text("◈ the futures reorganize…")
            .font(Tokens.Fonts.mono(11))
            .tracking(1.4)
            .foregroundStyle(Tokens.Role.secondaryInfo.opacity(0.7))
            .accessibilityIdentifier("chat.patchline")
    }
}

private struct StreamingRow: View {
    let text: String

    var body: some View {
        // Streaming reply with a cursor (§2.3, mock 8).
        Text(text + "▌")
            .font(Tokens.Fonts.mono(13))
            .foregroundStyle(Tokens.Role.displayText.opacity(0.9))
            .lineSpacing(5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
