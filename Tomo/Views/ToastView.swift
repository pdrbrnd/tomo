import SwiftUI

/// Cross-cutting feedback surface. One toast at a time; new toasts replace
/// the current one immediately. Slide in from the bottom, auto-dismiss
/// after `Toast.dismissAfter`. Visual language follows `DeviceTile` —
/// single-line capsule, semibold 12pt label, soft shadow.
///
/// Productionisation will extend this with stacking, swipe-to-dismiss, and
/// action buttons. The spike just needs a callable surface and a believable
/// visual.
struct Toast: Identifiable, Equatable {
    enum Kind: Equatable {
        case info
        case error
    }

    let id = UUID()
    let message: String
    let kind: Kind
    let dismissAfter: Duration

    static func info(_ message: String, dismissAfter: Duration = .seconds(3)) -> Toast {
        Toast(message: message, kind: .info, dismissAfter: dismissAfter)
    }

    static func error(_ message: String, dismissAfter: Duration = .seconds(5)) -> Toast {
        Toast(message: message, kind: .error, dismissAfter: dismissAfter)
    }
}

struct ToastView: View {
    let toast: Toast
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 13, height: 13)
            Text(toast.message)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .foregroundStyle(foregroundColor)
        .background(
            Capsule(style: .continuous)
                .fill(backgroundFill)
        )
        .clipShape(Capsule(style: .continuous))
        .softShadow(elevated: true)
    }

    private var iconName: String {
        switch toast.kind {
        case .info: return "info.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var foregroundColor: Color {
        switch toast.kind {
        case .info: return .primary
        case .error: return .white
        }
    }

    private var backgroundFill: Color {
        switch toast.kind {
        case .info:
            return colorScheme == .dark
                ? Color(white: 0.16)
                : Color(white: 0.97)
        case .error:
            return Color(red: 0.78, green: 0.22, blue: 0.18)
        }
    }
}
