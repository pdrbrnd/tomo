import SwiftUI

/// Wrap-as-needed layout for variable-width children: chips, tags, etc.
/// Lays out left-to-right, breaking to a new row whenever the next child
/// won't fit. Each row is the height of its tallest child plus `spacing`.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let containerWidth = proposal.width ?? .infinity
        let result = arrange(in: containerWidth, subviews: subviews)
        return CGSize(width: containerWidth, height: result.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(in: bounds.width, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            let size = result.sizes[index]
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
        }
    }

    private func arrange(in width: CGFloat, subviews: Subviews) -> (
        positions: [CGPoint], sizes: [CGSize], totalHeight: CGFloat
    ) {
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            sizes.append(size)
            x += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }

        return (positions, sizes, y + lineHeight)
    }
}
