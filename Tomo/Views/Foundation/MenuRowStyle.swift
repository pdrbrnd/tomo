import SwiftUI

/// Renders a Button as a full-width hover-highlight menu row — the building
/// block for popover menus, inspector action lists, and similar in-app menus.
///
/// Use as `.buttonStyle(MenuRowStyle())` on the parent VStack so all child
/// Buttons inherit the look. Honors `role: .destructive` for delete actions.
///
/// The row's hover highlight is inset horizontally by `Theme.Spacing.menuInset`
/// — so dividers (which fill full width) and rows are concentric. The popover
/// container only adds *vertical* padding; horizontal inset lives here.
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
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.menuItem, style: .continuous)
                    .fill(highlight)
            )
            .padding(.horizontal, Theme.Spacing.menuInset)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }

    private var isDestructive: Bool {
        configuration.role == .destructive
    }

    private var foreground: Color {
        if isDestructive { return .red.opacity(Theme.Text.primary) }
        return .primary.opacity(Theme.Text.primary)
    }

    private var highlight: Color {
        if isDestructive {
            if configuration.isPressed { return .red.opacity(Theme.Surface.dropTarget) }
            if hovered { return .red.opacity(Theme.Surface.selected) }
            return .clear
        }
        if configuration.isPressed { return .primary.opacity(Theme.Surface.press) }
        if hovered { return .primary.opacity(Theme.Surface.hover) }
        return .clear
    }
}

/// A horizontal divider sized for menu use: edge-to-edge (no horizontal
/// padding from container), with vertical padding that matches the popover's
/// menu inset so spacing reads consistent throughout.
struct MenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
            .padding(.vertical, Theme.Spacing.menuInset)
    }
}

/// Standard container for a popover-style menu. Wrap a `VStack` of Buttons in
/// this and they'll get full-width rows with inset spacing concentric to the
/// popover's outer radius. Vertical padding only — rows handle their own
/// horizontal inset so dividers can extend edge-to-edge.
extension View {
    func menuPopoverContainer(minWidth: CGFloat = 220) -> some View {
        self
            .buttonStyle(MenuRowStyle())
            .padding(.vertical, Theme.Spacing.menuInset)
            .frame(minWidth: minWidth)
            .background(Theme.canvas)
    }
}
