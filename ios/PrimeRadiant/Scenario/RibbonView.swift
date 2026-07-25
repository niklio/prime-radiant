import SwiftUI

/// One step of the selected path, root → current.
struct RibbonCrumb: Identifiable, Equatable {
    let id: String
    let label: String
}

/// The path ribbon (mock 5/6): its own line above the capsule, left-aligned,
/// horizontally scrollable with momentum and edge fades at every position.
/// Mono caps, letterspaced, `›` separators; ancestors dim amber, the current
/// node bright parchment. Tapping an ancestor jumps the selection (notes §2).
struct RibbonView: View {
    let crumbs: [RibbonCrumb]
    var onJump: (String) -> Void

    /// Content inset keeps the current crumb clear of the trailing fade.
    private static let inset: CGFloat = 26
    private static let fadeWidth: CGFloat = 20

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(crumbs.enumerated()), id: \.element.id) { index, crumb in
                    if index > 0 {
                        Text("›")
                            .font(Tokens.Fonts.mono(10))
                            .foregroundStyle(Tokens.Role.edgeNeutral.opacity(0.55))
                    }
                    Button {
                        guard index < crumbs.count - 1 else { return }
                        onJump(crumb.id)
                    } label: {
                        Text(crumb.label.uppercased())
                            .font(Tokens.Fonts.mono(10))
                            .tracking(1.8)
                            .foregroundStyle(
                                index == crumbs.count - 1
                                    ? Tokens.Role.displayText
                                    : Tokens.Role.edgeNeutral.opacity(0.75))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .accessibilityIdentifier("ribbon.item.\(index)")
                }
            }
            .padding(.horizontal, Self.inset)
        }
        .defaultScrollAnchor(.trailing)
        .mask(
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.fadeWidth)
                Rectangle().fill(.black)
                LinearGradient(
                    colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: Self.fadeWidth)
            })
        .frame(height: 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("canvas.ribbon")
    }
}
