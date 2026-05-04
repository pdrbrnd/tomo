import SwiftUI

@main
struct TomoApp: App {
  @State private var state = AppState()

  init() {
    // Must run before any window is shown so NSThemeFrame returns our
    // value the first time it lays out. macOS Tahoe doesn't expose a
    // public knob for window corner radius — see WindowChromeOverride.
    WindowChromeOverride.install(cornerRadius: Theme.Radius.window)
  }

  var body: some Scene {
    WindowGroup("Tomo") {
      LibraryView(state: state)
    }
    .windowStyle(.hiddenTitleBar)
    .windowToolbarStyle(.unifiedCompact)
    .defaultSize(width: 1200, height: 820)
    .commands {
      #if DEBUG
        CommandMenu("Debug") {
          Button("Toggle Fake Device") {
            state.toggleFakeDevice()
          }
          .keyboardShortcut("d", modifiers: [.command, .control])

          Button("Cycle Fake Send State") {
            state.cycleFakeSendState()
          }
          .keyboardShortcut("d", modifiers: [.command, .control, .shift])
        }
      #endif
    }

    Settings {
      SettingsView(state: state)
    }
  }
}
