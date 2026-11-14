import SwiftUI

enum AppAppearance: String, CaseIterable {
    case system
    case light
    case dark

    static let storageKey = "appearance.theme"
    static let coverSizeKey = "library.coverSize"
    static let libraryScrollBarKey = "appearance.alwaysShowLibraryScrollBar"

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct AppearanceSettingsView: View {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system
    @AppStorage(AppAppearance.coverSizeKey) private var coverSize = Theme.Library.defaultCoverSize
    @AppStorage(AppAppearance.libraryScrollBarKey) private var alwaysShowScrollBar = false

    private var coverSizeLabel: String { (coverSize / 100).formatted(.percent) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Picker("Theme", selection: $appearance) {
                ForEach(AppAppearance.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Divider()

            HStack(spacing: Theme.Spacing.md) {
                Text("Cover size")
                    .accessibilityHidden(true)

                Slider(value: $coverSize, in: Theme.Library.coverSizeRange, step: 5) {
                    Text("Cover size")
                }
                .labelsHidden()
                .accessibilityValue(Text(coverSizeLabel))

                Text(coverSizeLabel)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
                    .accessibilityHidden(true)
            }

            Divider()

            Toggle("Show library scroll bar", isOn: $alwaysShowScrollBar)
                .toggleStyle(.checkbox)

            Text("Keep a draggable scroll bar visible in the library and search results.")
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(Theme.Text.secondary))
        }
    }
}
