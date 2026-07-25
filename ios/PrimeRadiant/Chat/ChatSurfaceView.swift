import PrimeRadiantCore
import SwiftUI

/// The full-screen chat surface (§2.3): its own screen, never a half sheet.
/// The tree persists behind at ~15% opacity as ambience; `‹ CANVAS` returns;
/// messages stream full-width; a patch turn shows "◈ the futures reorganize…"
/// with a live mini-tree chip; the input pill (with mic) docks at the bottom.
struct ChatSurfaceView: View {
    @Bindable var store: ScenarioStore
    @State private var speech = SpeechInput()

    var body: some View {
        ZStack(alignment: .bottom) {
            Tokens.Role.background.ignoresSafeArea()

            // Ghosted tree ambience (tokens layout.chatSurfaceTreeOpacity).
            CanvasView(radiant: store.radiant, interactive: false)
                .opacity(Tokens.Layout.chatSurfaceTreeOpacity)
                .allowsHitTesting(false)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                messageList
                InputPillView(
                    speech: speech,
                    onOpenChat: {},
                    onSend: { store.send(text: $0) },
                    typesInline: true,
                    statusLine: store.composerStatusLine)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
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
                .font(Tokens.Fonts.display(19))
                .foregroundStyle(Tokens.Role.displayText)
                .lineLimit(1)
            HStack {
                Button(action: { store.closeChat() }) {
                    Text("‹ CANVAS")
                        .font(Tokens.Fonts.mono(12, medium: true))
                        .tracking(Tokens.Fonts.labelTracking)
                        .foregroundStyle(Tokens.Role.secondaryInfo)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    // Node-anchored context, shown once when opened from a node (§2.3 #4).
                    if let focusedId = store.focusedNodeId,
                        let node = Tree.find(store.scenario.tree, id: focusedId) {
                        Text("· about \(node.label) ·")
                            .font(Tokens.Fonts.mono(11))
                            .foregroundStyle(Tokens.Role.secondaryInfo.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    ForEach(Array(store.scenario.transcript.enumerated()), id: \.offset) { _, message in
                        MessageRow(message: message) {
                            store.closeChat()  // chip tap returns to the settling tree
                        }
                    }

                    if store.isStreaming {
                        StreamingRow(text: store.streamingSay)
                            .id("streaming")
                    }

                    if store.reorganizing {
                        ReorganizeRow { store.closeChat() }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: store.streamingSay) {
                proxy.scrollTo("streaming", anchor: .bottom)
            }
        }
    }
}

private struct MessageRow: View {
    let message: Message
    var onChipTap: () -> Void

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 10) {
            if message.role == .user {
                Text("“\(message.content)”")
                    .font(Tokens.Fonts.mono(14))
                    .foregroundStyle(Tokens.Role.displayText.opacity(0.95))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(Tokens.Role.displayText.opacity(0.07)))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text(message.content)
                    .font(Tokens.Fonts.mono(15))
                    .foregroundStyle(Tokens.Role.displayText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if message.patchApplied != nil {
                    HStack(alignment: .top, spacing: 14) {
                        Text("◈ the futures reorganize…")
                            .font(Tokens.Fonts.mono(12))
                            .tracking(1)
                            .foregroundStyle(Tokens.Role.secondaryInfo)
                        Spacer()
                        MiniTreeChip(onTap: onChipTap)
                    }
                }
            }
        }
    }
}

private struct StreamingRow: View {
    let text: String

    var body: some View {
        // Streaming reply with a cursor (§2.3).
        Text(text + "▊")
            .font(Tokens.Fonts.mono(15))
            .foregroundStyle(Tokens.Role.displayText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReorganizeRow: View {
    var onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("◈ the futures reorganize…")
                .font(Tokens.Fonts.mono(12))
                .tracking(1)
                .foregroundStyle(Tokens.Role.secondaryInfo)
            Spacer()
            MiniTreeChip(onTap: onTap)
        }
    }
}

/// Mini-tree chip: STUB — a static glyph standing in for the live patch-diff
/// animation (M2 polish: render the changed subtree animating in miniature).
/// Tapping it returns to the canvas with the new tree settling.
private struct MiniTreeChip: View {
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                MiniTreeGlyph()
                    .stroke(Tokens.Role.selectedPath, lineWidth: 1.5)
                    .frame(width: 72, height: 44)
                Text("VIEW CHANGE")
                    .font(Tokens.Fonts.mono(9, medium: true))
                    .tracking(Tokens.Fonts.labelTracking)
                    .foregroundStyle(Tokens.Role.secondaryInfo)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Tokens.Palette.void.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Tokens.Role.edgeNeutral.opacity(0.4), lineWidth: 1)))
        }
    }
}

private struct MiniTreeGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let root = CGPoint(x: rect.midX, y: rect.maxY)
        for (fx, fy) in [(0.2, 0.25), (0.45, 0.05), (0.75, 0.2), (0.95, 0.45)] {
            let tip = CGPoint(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy)
            path.move(to: root)
            path.addQuadCurve(
                to: tip,
                control: CGPoint(x: (root.x + tip.x) / 2, y: root.y - rect.height * 0.5))
        }
        return path
    }
}
