import SwiftUI

@main
struct AcervoApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Acervo") {
            LibraryView(state: state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1200, height: 820)

        Settings {
            SettingsView(state: state)
        }
    }
}
