import SwiftUI

@main
struct AcervoApp: App {
    @State private var state = AppState()

    init() {
        // Must run before any window is shown so NSThemeFrame returns our
        // value the first time it lays out. macOS Tahoe doesn't expose a
        // public knob for window corner radius — see WindowChromeOverride.
        WindowChromeOverride.install(cornerRadius: Theme.Radius.window)
    }

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
