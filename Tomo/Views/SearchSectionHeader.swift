import SwiftUI

/// Section header used by the search results list. One per section
/// (Library, then one per enabled plugin). The header carries:
///  - title (uppercase tracked — matches the sidebar's section style)
///  - per-source loading spinner or error icon (errors expand on click)
///  - result count (when the section is settled)
///
/// When `onToggle` is set, the title becomes a button that collapses /
/// expands the section. No chevron — discoverability comes from the
/// pointer cursor on hover, a soft hover tint, and the `.help()` tooltip.
struct SearchSectionHeader: View {
    let title: String
    var isLoading: Bool = false
    var failureMessage: String? = nil
    var resultCount: Int? = nil
    var isCollapsed: Bool = false
    var onToggle: (() -> Void)? = nil

    @State private var showingError = false
    @State private var titleHovering = false

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            titleButton
            Spacer(minLength: Theme.Spacing.md)
            trailingState
        }
        // 12pt horizontal padding aligns with `SearchResultRow`'s outer
        // padding so the header title sits directly above the rows' thumb
        // column. Vertical breathing room is on the bottom only — the
        // outer LazyVStack provides the gap above.
        .padding(.horizontal, 12)
        .padding(.bottom, Theme.Spacing.sm)
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

    @ViewBuilder
    private var trailingState: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 12, height: 12)
        } else if let message = failureMessage {
            // Icon-only by default. Clicking opens a popover with the full
            // message — keeps the header tight when the underlying error
            // string is long (NSError descriptions get verbose).
            Button {
                showingError = true
            } label: {
                Icon(symbol: "exclamationmark.triangle.fill", weight: .regular, size: 11)
                    .foregroundStyle(Color.red.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("Search failed — click for details")
            .popover(isPresented: $showingError, arrowEdge: .top) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(Theme.Text.primary))
                    .textSelection(.enabled)
                    .padding(Theme.Spacing.md)
                    .frame(maxWidth: 360, alignment: .leading)
            }
        } else if let count = resultCount {
            Text("\(count)")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary.opacity(Theme.Text.tertiary))
        }
    }
}
