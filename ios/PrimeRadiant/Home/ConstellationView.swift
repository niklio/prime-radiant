import PrimeRadiantCore
import SceneKit
import SwiftUI

/// The constellation home overlays (§2.2 + notes §1): every scenario is a
/// constellation at persistent shell coordinates in the ONE shared world scene
/// (hosted by RootView); this view carries only the labels and management
/// chrome. Status is luminance, not iconography — each cluster shows exactly
/// one serif title line (resolved clusters render dim; no glyphs, no
/// timestamps, no outcome text — divergence from the old status line already
/// logged). Tap dives; hold-and-drag lifts a cluster toward the ARCHIVE /
/// DELETE wells; `+` creates from anywhere.
struct ConstellationView: View {
    let radiant: RadiantScene
    let scenarios: [Scenario]
    let archivedCount: Int
    var onOpen: (String) -> Void
    var onCreate: () -> Void
    var onArchive: (String) -> Void
    var onDelete: (String) -> Void
    var onUndoDelete: (String) -> Void

    @State private var screenPositions: [String: CGPoint] = [:]
    /// Cluster currently lifted under the finger (hold-and-drag management).
    @State private var lifted: (id: String, offset: CGSize)?
    @State private var undoToastId: String?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if scenarios.isEmpty {
                    EmptyConstellation(onCreate: onCreate)
                } else {
                    clusterOverlays
                }

                topBar
                if archivedCount > 0 {
                    archivedEdge
                }
                if lifted != nil {
                    wells(in: geometry.size)
                }
                if let undoId = undoToastId {
                    undoToast(for: undoId)
                }
            }
        }
        .statusBarHidden()
        .task(id: scenarios.map(\.id)) {
            // Labels track their clusters through camera drift and flights.
            while !Task.isCancelled {
                screenPositions = radiant.clusterScreenPoints()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    // MARK: - Overlays

    private var topBar: some View {
        VStack {
            HStack {
                Text("YOUR FUTURES")
                    .font(Tokens.Fonts.mono(12, medium: true))
                    .tracking(Tokens.Fonts.labelTracking)
                    .foregroundStyle(Tokens.Role.edgeNeutral)
                Spacer()
                Button(action: onCreate) {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(Tokens.Role.displayText)
                }
                .accessibilityLabel("begin a scenario")
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            Spacer()
        }
    }

    private var clusterOverlays: some View {
        ForEach(scenarios) { scenario in
            if let position = screenPositions[scenario.id] {
                ClusterLabel(
                    scenario: scenario,
                    lifted: lifted?.id == scenario.id)
                    .position(position)
                    .offset(lifted?.id == scenario.id ? lifted!.offset : .zero)
                    .gesture(clusterGesture(for: scenario, at: position))
                    .accessibilityAddTraits(.isButton)
            }
        }
    }

    /// Tap dives (continuous camera flight, notes §3); hold lifts (haptic) and
    /// drags toward the wells (§2.2).
    private func clusterGesture(for scenario: Scenario, at position: CGPoint) -> some Gesture {
        let tap = TapGesture().onEnded {
            onOpen(scenario.id)
        }
        let holdDrag = LongPressGesture(minimumDuration: 0.35)
            .onEnded { _ in
                Haptics.lift()
                lifted = (scenario.id, .zero)
            }
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                if case .second(true, let drag?) = value {
                    lifted = (scenario.id, drag.translation)
                }
            }
            .onEnded { value in
                defer { lifted = nil }
                guard case .second(true, let drag?) = value else { return }
                let dropPoint = CGPoint(
                    x: position.x + drag.translation.width,
                    y: position.y + drag.translation.height)
                handleDrop(of: scenario.id, at: dropPoint)
            }
        return tap.exclusively(before: holdDrag)
    }

    private func handleDrop(of id: String, at point: CGPoint) {
        guard let well = WellsLayout.well(containing: point, in: UIScreen.main.bounds.size)
        else {
            Haptics.settle()  // released anywhere else: settles back
            return
        }
        switch well {
        case .archive:
            onArchive(id)
        case .delete:
            // Soft-delete server-side, 30-day purge, single undo toast (§2.2).
            onDelete(id)
            undoToastId = id
        }
    }

    private func wells(in size: CGSize) -> some View {
        HStack(spacing: 18) {
            WellView(label: "ARCHIVE", color: Tokens.Role.secondaryInfo)
            WellView(label: "DELETE", color: Tokens.Role.terminalAdverse)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 36)
        .transition(.opacity)
    }

    private func undoToast(for id: String) -> some View {
        VStack {
            Spacer()
            Button {
                onUndoDelete(id)
                undoToastId = nil
            } label: {
                Text("deleted · undo")
                    .font(Tokens.Fonts.mono(12))
                    .foregroundStyle(Tokens.Role.displayText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Tokens.Palette.void.opacity(0.92)))
                    .overlay(Capsule().strokeBorder(Tokens.Role.displayText.opacity(0.25), lineWidth: 1))
            }
            .padding(.bottom, 24)
            .task {
                try? await Task.sleep(for: .seconds(5))
                undoToastId = nil
            }
        }
    }

    /// Archived scenarios collapse into a dim cluster at the constellation's far
    /// edge (§2.2). M3: pinching into it reveals them; for now it only glows.
    private var archivedEdge: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text("· archived \(archivedCount)")
                    .font(Tokens.Fonts.mono(10))
                    .tracking(1.5)
                    .foregroundStyle(Tokens.Role.displayText.opacity(0.25))
                    .padding(.trailing, 20)
                    .padding(.bottom, 16)
            }
        }
    }
}

// MARK: - Wells

private enum WellsLayout {
    enum Well { case archive, delete }

    /// Two drop targets along the bottom edge; geometry mirrored in WellView.
    static func well(containing point: CGPoint, in size: CGSize) -> Well? {
        guard point.y > size.height - 140 else { return nil }
        return point.x < size.width / 2 ? .archive : .delete
    }
}

private struct WellView: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(Tokens.Fonts.mono(11, medium: true))
            .tracking(Tokens.Fonts.labelTracking)
            .foregroundStyle(color)
            .frame(width: 140, height: 64)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(color.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}

// MARK: - Cluster label (exactly one serif title — notes §4)

private struct ClusterLabel: View {
    let scenario: Scenario
    let lifted: Bool

    var body: some View {
        VStack(spacing: 3) {
            // Invisible hit area over the cluster itself.
            Color.clear
                .frame(width: 110, height: 90)
                .contentShape(Rectangle())
            // Status is luminance, not iconography: resolved constellations
            // dim to 42% with a dimmed label; no glyphs, no status text.
            Text(scenario.title)
                .font(Tokens.Fonts.display(19))
                .foregroundStyle(
                    Tokens.Role.displayText.opacity(
                        scenario.status == .resolved
                            ? Tokens.World.resolvedClusterLuminance : 0.85))
                .lineLimit(1)
        }
        .scaleEffect(lifted ? 1.08 : 1)
        .shadow(color: lifted ? Tokens.Role.selectedPath.opacity(0.4) : .clear, radius: 12)
        .animation(.easeOut(duration: 0.2), value: lifted)
    }
}

// MARK: - Empty state: one pulsing unborn node (§2.2, motion tokens)

private struct EmptyConstellation: View {
    var onCreate: () -> Void
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 20) {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Tokens.Role.selectedPath, .clear],
                        center: .center, startRadius: 2, endRadius: 30))
                .frame(width: 60, height: 60)
                // ±20% glow radius over a ~2.4s period (motion tokens).
                .scaleEffect(pulse ? 1 + Tokens.Motion.unbornPulseGlowDelta : 1 - Tokens.Motion.unbornPulseGlowDelta)
                .animation(
                    Motion.isReduced
                        ? nil
                        : .easeInOut(duration: Tokens.Motion.unbornPulsePeriodSeconds / 2)
                            .repeatForever(autoreverses: true),
                    value: pulse)
            Text("begin a scenario")
                .font(Tokens.Fonts.mono(13))
                .tracking(1.5)
                .foregroundStyle(Tokens.Role.displayText.opacity(0.6))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onCreate)
        .onAppear { pulse = true }
    }
}
