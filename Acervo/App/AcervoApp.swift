import SwiftUI

@main
struct AcervoApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Acervo") {
            LibraryView(state: state)
        }

        Settings {
            SettingsView(state: state)
        }
    }
}
