import SwiftUI

/// Settings sidebar — same row vocabulary as `LibrarySidebar` (shared
/// `SidebarRowStyle`), but a flat list of sections instead of the library's
/// nested device/collections/languages structure.
struct SettingsSidebar: View {
    @Binding var selection: SettingsSection

    var body: some View {
        Theme.panel
            .overlay {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(SettingsSection.allCases) { section in
                            row(for: section)
                        }
                    }
                    .padding(.top, Theme.Chrome.paneTopReserve)
                    .padding(.horizontal, Theme.Spacing.menuInset)
                    .padding(.bottom, Theme.Chrome.paneBottomReserve)
                }
            }
    }

    private func row(for section: SettingsSection) -> some View {
        Button {
            selection = section
        } label: {
            HStack(spacing: 9) {
                Icon(symbol: section.symbol, weight: .regular, size: 13)
                    .frame(width: 14)
                    .foregroundStyle(.primary.opacity(rowOpacity(for: section)))
                Text(section.title)
                    .font(.system(size: 13, weight: selection == section ? .semibold : .regular))
                    .foregroundStyle(.primary.opacity(rowOpacity(for: section)))
                    .lineLimit(1)
                Spacer()
            }
        }
        .buttonStyle(SidebarRowStyle(isSelected: selection == section))
    }

    private func rowOpacity(for section: SettingsSection) -> Double {
        selection == section ? Theme.Text.emphatic : Theme.Text.muted
    }
}
