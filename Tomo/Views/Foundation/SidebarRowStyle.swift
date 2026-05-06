import SwiftUI

/// Sidebar row with persistent selection highlight (vs `MenuRowStyle`,
/// which only handles hover/press). Selection is sticky; hover is softer;
/// press is the strongest. Drop-targeting and the post-drop flash use the
/// neutral `.primary` colour so the highlight reads against accent content.
///
/// Lifted from `LibrarySidebar` so settings sidebars (and any future
/// sidebar-shaped surfaces) can share the same vocabulary.
struct SidebarRowStyle: ButtonStyle {
    let isSelected: Bool
    var isDropTargeted: Bool = false
    var recentlyDropped: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        SidebarRowBody(
            configuration: configuration,
            isSelected: isSelected,
            isDropTargeted: isDropTargeted,
            recentlyDropped: recentlyDropped
        )
    }
}

private struct SidebarRowBody: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    let isDropTargeted: Bool
    let recentlyDropped: Bool
    @State private var hovered = false

    var body: some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sidebarRow, style: .continuous)
                    .fill(highlight)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sidebarRow, style: .continuous)
                    .fill(.primary.opacity(recentlyDropped ? Theme.Surface.dropFlash : 0))
                    .animation(.easeOut(duration: 0.45), value: recentlyDropped)
            )
            .padding(.horizontal, Theme.Spacing.menuInset)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }

    private var highlight: Color {
        if isDropTargeted { return .primary.opacity(Theme.Surface.dropTarget) }
        if isSelected { return .primary.opacity(Theme.Surface.selected) }
        if configuration.isPressed { return .primary.opacity(Theme.Surface.pressSoft) }
        if hovered { return .primary.opacity(Theme.Surface.hoverSoft) }
        return .clear
    }
}
