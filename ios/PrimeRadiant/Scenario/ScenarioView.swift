import PrimeRadiantCore
import SwiftUI

/// The scenario canvas (§2.3): the tree owns the full screen. No headers, no
/// chrome bars — exactly three overlays: input pill, node footer, breadcrumb
/// (legend stands in for the footer when nothing is selected). No coach marks,
/// no hint text, no gesture instructions, anywhere.
struct ScenarioView: View {
    @Bindable var store: ScenarioStore
    @State private var speech = SpeechInput()

    var body: some View {
        ZStack(alignment: .bottom) {
            canvas
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                // Footer and breadcrumb are ONE stacked container: overlap is
                // structurally impossible (§2.3, asserted by snapshot test §8).
                if let node = store.selectedNode {
                    NodeFooterView(
                        node: node,
                        nodeAnalytics: store.selectedAnalytics,
                        unit: store.scenario.payoffUnit,
                        isDistributionExpanded: $store.isDistributionExpanded,
                        onOpenChat: { store.openChat(focusedNodeId: node.id) })
                    Divider().overlay(Tokens.Role.displayText.opacity(0.12))
                    BreadcrumbView(labels: store.breadcrumb)
                } else {
                    LegendView()
                }

                // Voice sends straight from the canvas — the reply lands as a
                // reorganized tree; typing routes to the full-screen chat surface.
                InputPillView(
                    speech: speech,
                    onOpenChat: { store.openChat(focusedNodeId: nil) },
                    onSend: { store.send(text: $0) })
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .background(Tokens.Role.background)
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
    }

    private var canvas: CanvasView {
        var canvas = CanvasView(
            radiant: store.radiant,
            interactive: true,
            callbacks: CanvasCallbacks(
                onSelect: { store.select($0) },
                holdIntent: { store.holdIntent(for: $0) },
                onHoldCompleted: { id, intent in store.completeHold(id: id, intent: intent) }))
        #if DEBUG
            // UI-test hooks (§8): per-node accessibility elements + canvas state,
            // only under `-PRUITestHooks` (mirrors -PRDebugSample gating).
            if UITestHooks.enabled {
                let store = self.store
                canvas.hooksState = {
                    var labels: [String: String] = [:]
                    Tree.forEach(store.scenario.tree) { labels[$0.id] = $0.label }
                    return CanvasHooksState(
                        nodeLabels: labels,
                        stateValue:
                            "selected=\(store.selectedNodeId ?? "none") reached=\(store.scenario.realizedPath.count)"
                    )
                }
            }
        #endif
        return canvas
    }
}

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
