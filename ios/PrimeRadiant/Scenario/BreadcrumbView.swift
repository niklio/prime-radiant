import SwiftUI

/// Breadcrumb root→selected. On compact widths, condenses to
/// `ROOT › … › parent › current` (§2.3) — keyed on size class, not device (§7).
struct BreadcrumbView: View {
    let labels: [String]

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Text(condensed.joined(separator: " › "))
            .font(Tokens.Fonts.mono(11, medium: true))
            .tracking(1.5)
            .foregroundStyle(Tokens.Role.secondaryInfo.opacity(0.85))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var condensed: [String] {
        let upper = labels.map { $0.uppercased() }
        guard sizeClass != .regular, upper.count > 3 else { return upper }
        return ["ROOT", "…", upper[upper.count - 2], upper[upper.count - 1]]
    }
}
