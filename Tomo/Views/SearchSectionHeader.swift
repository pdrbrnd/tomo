import SwiftUI

/// Section header used by the search results list. One per section
/// (Library, then one per enabled plugin). The header carries:
///  - title (uppercase tracked — matches the sidebar's section style)
///  - per-source loading spinner or error pill
///  - result count (when the section is settled)
///  - optional subtitle (e.g. "Downloads will add to <collection>")
struct SearchSectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var isLoading: Bool = false
    var failureMessage: String? = nil
    var resultCount: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(Theme.Text.secondary))
                    .tracking(0.2)
                    .textCase(.uppercase)

                Spacer(minLength: Theme.Spacing.md)

                trailingState
            }

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(Theme.Text.tertiary))
            }
        }
        .padding(.horizontal, Theme.Spacing.menuInset + Theme.Spacing.md)
        .padding(.top, Theme.Spacing.lg)
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
            HStack(spacing: 4) {
                Icon(symbol: "exclamationmark.triangle.fill", weight: .regular, size: 10)
                    .foregroundStyle(Color.red.opacity(0.85))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(Theme.Text.tertiary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else if let count = resultCount {
            Text("\(count)")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary.opacity(Theme.Text.tertiary))
        }
    }
}
