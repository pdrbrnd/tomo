import SwiftUI

@main
struct TintaApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Tinta") {
            LibraryView(state: state)
        }

        Settings {
            SettingsView(state: state)
        }
    }
}
