import SwiftUI
import PhosphorSwift

/// Floating bottom-right tile shown when a device (Kindle, etc.) is connected.
///
/// One single-line capsule that morphs through six visual states. The body
/// shape stays constant (HStack { icon, text }) so SwiftUI can interpolate
/// scale, fill, and content rather than swap-cutting between layouts.
///
/// States in priority order:
///  - sending/success/error  — driven by `sendState` post-drop
///  - dragOver               — drop is currently over the tile
///  - dragActive             — any in-app drag is happening (attention grab)
///  - idle                   — nothing happening
struct DeviceTile: View {
    let displayName: String
    let bookCount: Int
    let inAppDragCount: Int
    let sendState: DeviceSendState
    let onEject: () -> Void
    /// Returns whether the drop was accepted.
    let onDrop: (BookDrag) -> Bool

    @State private var dropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Visual: Equatable {
        case idle
        case dragActive(count: Int)
        case dragOver(count: Int)
        case sending(completed: Int, total: Int)
        case success(count: Int)
        case error
    }

    private var visual: Visual {
        switch sendState {
        case .sending(let completed, let total): return .sending(completed: completed, total: total)
        case .success(let count): return .success(count: count)
        case .error: return .error
        case .idle: break
        }
        if dropTargeted { return .dragOver(count: max(inAppDragCount, 1)) }
        if inAppDragCount > 0 { return .dragActive(count: inAppDragCount) }
        return .idle
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            iconView
                .frame(width: 13, height: 13)
            Text(primaryLabel)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .contentTransition(.numericText())
                .id(primaryLabel)
            if let trailing = trailingLabel {
                Text(trailing)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .opacity(0.62)
                    .padding(.leading, -2)
                    .lineLimit(1)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .foregroundStyle(foregroundColor)
        .background(
            Capsule(style: .continuous)
                .fill(backgroundFill)
        )
        .overlay(progressBar)
        .clipShape(Capsule(style: .continuous))
        // Scale from the bottom-right so the tile grows up-and-leftward —
        // it sits in the bottom-right corner of the window, so center-scaling
        // would push it past the right edge.
        .scaleEffect(scaleAmount, anchor: .bottomTrailing)
        .softShadow(elevated: visual != .idle)
        .animation(stateAnimation, value: visual)
        .contextMenu {
            Button("Eject \(displayName)", action: onEject)
        }
        .dropDestination(for: BookDrag.self) { drags, _ in
            let allIDs = drags.flatMap(\.bookIDs)
            guard !allIDs.isEmpty else { return false }
            return onDrop(BookDrag(bookIDs: allIDs))
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
    }

    // MARK: - Content

    private var primaryLabel: String {
        switch visual {
        case .idle, .dragActive: return displayName
        case .dragOver(let count):
            return count > 1 ? "Send \(count) to \(displayName)" : "Send to \(displayName)"
        case .sending(let completed, let total):
            return "Sending \(completed)/\(total)"
        case .success(let count):
            return count > 1 ? "Sent \(count) books" : "Sent"
        case .error: return "Send failed"
        }
    }

    /// Trailing monospaced label — only the book count, in idle/dragActive.
    /// Drag-over and post-drop states put their info in `primaryLabel`.
    private var trailingLabel: String? {
        switch visual {
        case .idle, .dragActive: return "\(bookCount)"
        default: return nil
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch visual {
        case .success:
            Icon(symbol: .check, weight: .bold, size: 13)
                .transition(.opacity.combined(with: .scale))
        case .error:
            Icon(symbol: .x, weight: .bold, size: 13)
                .transition(.opacity.combined(with: .scale))
        case .sending:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.65)
                .tint(.white)
                .transition(.opacity)
        default:
            Icon(symbol: .deviceTablet, weight: .regular, size: 13)
                .transition(.opacity)
        }
    }

    // MARK: - Visual properties

    private var foregroundColor: Color {
        switch visual {
        case .dragOver, .sending, .success, .error: return .white
        case .idle, .dragActive: return Theme.canvas
        }
    }

    private var backgroundFill: Color {
        switch visual {
        case .dragOver, .sending, .success: return .accentColor
        case .error: return Color.red.opacity(0.92)
        case .idle, .dragActive: return Color.primary.opacity(0.92)
        }
    }

    private var scaleAmount: CGFloat {
        if reduceMotion { return 1.0 }
        switch visual {
        case .idle: return 1.0
        case .dragActive: return 1.10   // attention grab when any in-app drag starts
        case .dragOver: return 1.20     // strong reaction when drag is over us
        case .sending: return 1.06
        case .success: return 1.10      // celebratory pop
        case .error: return 1.04
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if case .sending(let completed, let total) = visual {
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.white.opacity(0.32))
                    .frame(
                        width: geo.size.width * CGFloat(max(0, min(1, Double(completed) / Double(max(1, total))))),
                        height: 2
                    )
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    private var stateAnimation: Animation {
        if reduceMotion { return .easeOut(duration: 0.18) }
        switch visual {
        case .dragActive: return .spring(duration: 0.36, bounce: 0.45)
        case .dragOver: return .spring(duration: 0.30, bounce: 0.28)
        case .success: return .spring(duration: 0.32, bounce: 0.32)
        case .error: return .snappy(duration: 0.22, extraBounce: 0.15)
        case .sending: return .smooth(duration: 0.22)
        case .idle: return .smooth(duration: 0.30, extraBounce: 0.10)
        }
    }
}
