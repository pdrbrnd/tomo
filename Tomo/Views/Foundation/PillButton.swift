import SwiftUI

/// 32pt-tall capsule button. Matches the height and shape vocabulary of
/// `SearchPill` and `GalleryQueryField` so a row of inputs + buttons reads
/// as one cohesive control strip.
///
/// Two variants:
/// - default: `Theme.surface` fill + `Theme.hairline` border, neutral text
/// - prominent: accent fill, white text, no border
struct PillButtonStyle: ButtonStyle {
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, prominent: prominent)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let prominent: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .semibold : .regular))
            .foregroundStyle(foreground)
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(height: 32)
            .background(
                ZStack {
                    Capsule(style: .continuous).fill(backgroundFill)
                    if !prominent {
                        Capsule(style: .continuous).stroke(Theme.hairline, lineWidth: 0.5)
                    }
                }
            )
            .opacity(isEnabled ? 1.0 : 0.5)
            .contentShape(Capsule(style: .continuous))
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private var foreground: Color {
        prominent ? Color.white : Color.primary.opacity(0.92)
    }

    private var backgroundFill: Color {
        if prominent {
            if configuration.isPressed { return Color.accentColor.opacity(0.82) }
            if hovered { return Color.accentColor.opacity(0.92) }
            return Color.accentColor
        }
        if configuration.isPressed { return Color.primary.opacity(0.10) }
        if hovered { return Color.primary.opacity(0.05) }
        return Theme.surface
    }
}
