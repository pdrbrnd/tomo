import SwiftUI
import PhosphorSwift

/// Floating bottom-right tile shown when a device (Kindle, etc.) is connected.
/// Drop targeted handling and animations live here; the parent passes
/// callbacks for actual side effects.
struct DeviceTile: View {
    let displayName: String
    let bookCount: Int
    let onEject: () -> Void
    let onDrop: ([URL]) -> Bool

    @State private var dropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Icon(symbol: .deviceTablet, weight: .regular, size: 13)
            Text(displayName)
                .font(.system(size: 12, weight: .semibold))
            Text("\(bookCount)")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .opacity(0.62)
                .padding(.leading, -2)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .foregroundStyle(Theme.canvas)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.92))
        )
        .scaleEffect(reduceMotion ? 1.0 : (dropTargeted ? 1.04 : 1.0))
        .softShadow(elevated: dropTargeted)
        .animation(
            reduceMotion
                ? .easeOut(duration: 0.15)
                : .snappy(duration: 0.22, extraBounce: 0.10),
            value: dropTargeted
        )
        .contextMenu {
            Button("Eject \(displayName)", action: onEject)
        }
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
    }
}
