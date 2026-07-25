import PrimeRadiantCore
import SwiftUI

/// The scenario canvas overlays (§2.3): the tree owns the full screen. The
/// SCNView itself is hosted persistently by RootView (one scene, one camera —
/// notes §1); this view carries only the bottom chrome: the path ribbon and the
/// composer capsule (one stacked container — overlap structurally impossible).
/// While the radiant listens, the capsule gives way to the voice surface
/// (mock 9). No coach marks, no hint text, no gesture instructions, anywhere.
struct ScenarioView: View {
    @Bindable var store: ScenarioStore
    @State private var speech = SpeechInput()

    var body: some View {
        ZStack(alignment: .bottom) {
            if speech.isListening {
                VoiceListeningView(speech: speech)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    // Ribbon on its own line above the capsule (mock 5): the
                    // real selected path, root ancestors › current.
                    if !store.ribbon.isEmpty {
                        RibbonView(crumbs: store.ribbon) { store.select($0) }
                    }
                    ComposerCapsuleView(
                        context: store.capsuleContext,
                        isExpanded: $store.isDistributionExpanded,
                        speech: speech,
                        placeholder: store.selectedNode == nil
                            ? "describe the decision…" : "ask about this branch…",
                        onOpenChat: { store.openChat(focusedNodeId: store.selectedNodeId) },
                        onSend: { store.send(text: $0) },
                        statusLine: store.composerStatusLine)
                        .padding(.horizontal, 20)
                }
                .padding(.bottom, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(.container, edges: .bottom)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden()
        .onChange(of: speech.isListening) { _, listening in
            // The tree subtly brightens while the radiant listens (§2.3).
            store.radiant.setListening(listening)
        }
        .fullScreenCover(isPresented: $store.isChatPresented) {
            ChatSurfaceView(store: store)
        }
        .sheet(item: $store.pendingResolveNodeId) { terminalId in
            ResolveSheet(store: store, terminalId: terminalId)
                .presentationDetents([.height(240)])
                .presentationBackground(Tokens.Role.background)
        }
        .errorToast($store.lastError)
        #if DEBUG
            .overlay { debugOverlays }
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-PRDebugVoice") {
                    speech.debugFakeListening(
                        transcript: "she came back at forty, and honestly the timeline")
                    store.radiant.setListening(true)
                }
            }
        #endif
    }

    #if DEBUG
        /// `-PRDebugMark` freezes the shared hold-ring mid-fill over the marked
        /// node so the ring itself can be screenshot-compared against mock 7.
        @ViewBuilder
        private var debugOverlays: some View {
            if ProcessInfo.processInfo.arguments.contains("-PRDebugMark"),
                let nodeId = store.scenario.realizedPath.last {
                DebugFrozenRing(radiant: store.radiant, nodeId: nodeId)
                    .allowsHitTesting(false)
            }
        }
    #endif
}

#if DEBUG
    private struct DebugFrozenRing: View {
        let radiant: RadiantScene
        let nodeId: String
        @State private var point: CGPoint?

        var body: some View {
            ZStack {
                if let point {
                    HoldRingView(progress: 0.72)
                        .frame(width: 64, height: 64)
                        .position(point)
                }
            }
            .ignoresSafeArea()
            .task {
                while !Task.isCancelled {
                    if let view = radiant.hostView {
                        point = radiant.projectedPoint(of: nodeId, in: view)
                    }
                    try? await Task.sleep(for: .milliseconds(66))
                }
            }
        }
    }
#endif

extension String: @retroactive Identifiable {
    public var id: String { self }
}

/// The resolve flow (§2.3): hold a terminal → optional actual-payoff entry →
/// calibration note. Sparse, lowercase, no ceremony (§10).
private struct ResolveSheet: View {
    @Bindable var store: ScenarioStore
    let terminalId: String
    @State private var payoffText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("this future arrived")
                .font(Tokens.Fonts.display(24))
                .foregroundStyle(Tokens.Role.displayText)

            TextField(
                "", text: $payoffText,
                prompt: Text("actual payoff · optional")
                    .foregroundStyle(Tokens.Role.displayText.opacity(0.35))
            )
            .font(Tokens.Fonts.mono(15))
            .keyboardType(.numbersAndPunctuation)
            .foregroundStyle(Tokens.Role.displayText)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Tokens.Role.secondaryInfo.opacity(0.3), lineWidth: 1))

            if let note = store.calibrationLine(for: terminalId, actual: Double(payoffText)) {
                Text(note)
                    .font(Tokens.Fonts.mono(12))
                    .foregroundStyle(Tokens.Role.secondaryInfo)
            }

            Button {
                store.resolve(actualPayoff: Double(payoffText))
            } label: {
                Text("resolve")
                    .font(Tokens.Fonts.mono(14, medium: true))
                    .foregroundStyle(Tokens.Palette.void)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Tokens.Role.payoffPositive))
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Tokens.Role.background)
    }
}

/// Error voice (§10): states what happened and the next action; no apologies,
/// no exclamation points. Auto-dismisses.
struct ErrorToast: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message {
                Text(message)
                    .font(Tokens.Fonts.mono(12))
                    .foregroundStyle(Tokens.Role.displayText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(Tokens.Palette.void.opacity(0.92))
                            .overlay(
                                Capsule().strokeBorder(
                                    Tokens.Role.terminalAdverse.opacity(0.5), lineWidth: 1)))
                    .padding(.top, 8)
                    .transition(.opacity)
                    .task {
                        try? await Task.sleep(for: .seconds(4))
                        self.message = nil
                    }
            }
        }
    }
}

extension View {
    func errorToast(_ message: Binding<String?>) -> some View {
        modifier(ErrorToast(message: message))
    }
}
