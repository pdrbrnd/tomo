import SwiftUI

/// Section header used by the search results list. One per section
/// (Library, then one per enabled plugin). Wraps the shared
/// `SectionHeader` and supplies the search-specific trailing state:
///  - per-source loading spinner or error icon (errors expand on click)
///  - result count (when the section is settled)
struct SearchSectionHeader: View {
    let title: String
    var isLoading: Bool = false
    var failureMessage: String? = nil
    var resultCount: Int? = nil
    var isCollapsed: Bool = false
    var onToggle: (() -> Void)? = nil

    @State private var showingError = false

    var body: some View {
        SectionHeader(
            title: title,
            isCollapsed: isCollapsed,
            onToggle: onToggle,
            trailing: { trailingState }
        )
        // 12pt horizontal padding aligns with `SearchResultRow`'s outer
        // padding so the header title sits directly above the rows' thumb
        // column. Vertical breathing room is on the bottom only — the
        // outer LazyVStack provides the gap above.
        .padding(.horizontal, 12)
        .padding(.bottom, Theme.Spacing.sm)
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
