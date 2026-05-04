import SwiftUI

/// Full-window drop indicator shown while the user is dragging external files
/// over the library. The parent controls visibility; this view is purely
/// presentational.
struct DropOverlay: View {
    /// The window's outer corner radius — used to compute the inner dashed
    /// border's concentric corner.
    var windowCornerRadius: CGFloat = Theme.Radius.window

    var body: some View {
        let gap = Theme.Spacing.sm
        let innerCorner = max(2, windowCornerRadius - gap)
        return ZStack {
            Theme.canvas.opacity(0.78)
            RoundedRectangle(cornerRadius: innerCorner, style: .continuous)
                .stroke(.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .padding(gap)
            VStack(spacing: Theme.Spacing.sm) {
                Icon(symbol: "square.and.arrow.down", weight: .light, size: 22)
                    .foregroundStyle(.primary.opacity(Theme.Text.secondary))
                Text("Drop to add to library")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                    .tracking(0.1)
            }
        }
        .allowsHitTesting(false)
    }
}
