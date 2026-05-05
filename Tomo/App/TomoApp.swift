import Combine
import Sparkle
import SwiftUI

@main
struct TomoApp: App {
    @State private var state = AppState()
    private let updaterController: SPUStandardUpdaterController

    init() {
        // Must run before any window is shown so NSThemeFrame returns our
        // value the first time it lays out. macOS Tahoe doesn't expose a
        // public knob for window corner radius — see WindowChromeOverride.
        WindowChromeOverride.install(cornerRadius: Theme.Radius.window)

        // Sparkle owns its own lifecycle once started. Feed URL + public
        // EdDSA key live in Info.plist (`SUFeedURL`, `SUPublicEDKey`).
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        WindowGroup("Tomo") {
            LibraryView(state: state)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1200, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
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
    }
}

/// Tracks Sparkle's `canCheckForUpdates` so the menu item greys out while
/// an update check or download is already in flight.
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}
