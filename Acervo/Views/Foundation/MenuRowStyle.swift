import SwiftUI

/// Renders a Button as a full-width hover-highlight menu row — the building
/// block for popover menus, inspector action lists, and similar in-app menus.
///
/// Use as `.buttonStyle(MenuRowStyle())` on the parent VStack so all child
/// Buttons inherit the look. Honors `role: .destructive` for delete actions.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRowBody(configuration: configuration)
    }
}

private struct MenuRowBody: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.menuItem, style: .continuous)
                    .fill(highlight)
            )
            .onHover { hovered = $0 }
    }

    private var isDestructive: Bool {
        configuration.role == .destructive
    }

    private var foreground: Color {
        if isDestructive { return Color.red.opacity(0.92) }
        return Color.primary.opacity(0.92)
    }

    private var highlight: Color {
        if isDestructive {
            if configuration.isPressed { return Color.red.opacity(0.18) }
            if hovered { return Color.red.opacity(0.10) }
            return .clear
        }
        // Neutral — `.primary` auto-adapts to color scheme.
        if configuration.isPressed { return Color.primary.opacity(0.12) }
        if hovered { return Color.primary.opacity(0.06) }
        return .clear
    }
}

/// Standard container for a popover-style menu. Wrap a `VStack` of Buttons in
/// this and they'll get full-width rows with inset spacing concentric to the
/// popover's outer radius.
extension View {
    func menuPopoverContainer(minWidth: CGFloat = 220) -> some View {
        self
            .buttonStyle(MenuRowStyle())
            .padding(Theme.Spacing.menuInset)
            .frame(minWidth: minWidth)
            .background(Theme.canvas)
    }
}
