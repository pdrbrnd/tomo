import SwiftUI
import PhosphorSwift

/// Language filter popover. Pure view — the parent owns the selection and
/// passes counts; this view just renders rows and reports back.
struct LanguageFilterPopover: View {
    let counts: [String: Int]
    let total: Int
    @Binding var selected: String?
    let onSelect: () -> Void

    private var sortedLocales: [String] {
        counts.keys.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            heading

            Button {
                selected = nil
                onSelect()
            } label: {
                row(label: "All", count: total, isSelected: selected == nil)
            }

            ForEach(sortedLocales, id: \.self) { tag in
                let display = Locale.current.localizedString(forIdentifier: tag) ?? tag
                Button {
                    selected = (selected == tag) ? nil : tag
                    onSelect()
                } label: {
                    row(label: display, count: counts[tag] ?? 0, isSelected: selected == tag)
                }
            }
        }
        .menuPopoverContainer(minWidth: 220)
    }

    private var heading: some View {
        Text("Language")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary.opacity(0.55))
            .tracking(0.2)
            .textCase(.uppercase)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, Theme.Spacing.sm)
            .padding(.bottom, Theme.Spacing.xs)
    }

    private func row(label: String, count: Int, isSelected: Bool) -> some View {
        HStack {
            Icon(symbol: .check, weight: .bold, size: 11)
                .foregroundStyle(.primary)
                .opacity(isSelected ? 0.85 : 0)
                .frame(width: 12)
            Text(label)
            Spacer()
            Text("\(count)")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.45))
        }
    }
}
