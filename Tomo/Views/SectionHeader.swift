import SwiftUI

/// Uppercase-tracked section header used across the app — sidebar sections
/// (Collections, Languages, Authors…) and search-results sections (Library,
/// per-plugin) share this primitive.
///
/// When `onToggle` is set, the title becomes a button with a soft hover tint
/// and a tooltip. There's no chevron — discoverability comes from the pointer
/// cursor on hover. Consumers add their own outer padding; this view only
/// styles the title + supplies the trailing slot.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var isCollapsed: Bool = false
    var onToggle: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    @State private var titleHovering = false

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            titleButton
            Spacer(minLength: Theme.Spacing.md)
            trailing()
        }
    }

    @ViewBuilder
    private var titleButton: some View {
        let titleText = Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary.opacity(Theme.Text.secondary))
            .tracking(0.2)
            .textCase(.uppercase)

        if let onToggle {
            Button(action: onToggle) {
                titleText
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.primary.opacity(titleHovering ? Theme.Surface.hoverSoft : 0))
                    )
                    .contentShape(Rectangle())
                    .padding(.horizontal, -6)
                    .padding(.vertical, -3)
            }
            .buttonStyle(.plain)
            .onHover { titleHovering = $0 }
            .help(isCollapsed ? "Click to expand this section" : "Click to collapse this section")
        } else {
            titleText
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(
        title: String,
        isCollapsed: Bool = false,
        onToggle: (() -> Void)? = nil
    ) {
        self.init(
            title: title,
            isCollapsed: isCollapsed,
            onToggle: onToggle,
            trailing: { EmptyView() }
        )
    }
}
