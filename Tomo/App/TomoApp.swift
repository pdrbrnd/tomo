import AppKit
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

        // Crash reporting before Sparkle so it catches updater errors too.
        // No-op if user opted out or no DSN is baked into Info.plist.
        CrashReporter.start()

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
            // Hijack the standard "Settings…" menu item (and its ⌘,
            // shortcut) to open our custom settings Window instead of the
            // default `Settings { }` scene — we want full control of the
            // chrome to match the library window.
            CommandGroup(replacing: .appSettings) {
                OpenSettingsButton()
            }
            LibraryMenuCommands(state: state)
            CommandGroup(replacing: .help) {
                FeedbackMenuItems()
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

                    Divider()

                    Button("Send Test Sentry Event") {
                        CrashReporter.captureTestEvent()
                    }
                }
            #endif
        }

        Window("Settings", id: Self.settingsWindowID) {
            SettingsRoot(state: state)
        }
        .windowStyle(.hiddenTitleBar)
        // `.contentSize` + a fixed frame on the content view = the window
        // sizes to the content and the user can't resize it.
        .windowResizability(.contentSize)
        .commandsRemoved()
    }

    /// Stable identifier so `OpenSettingsButton` can target this window
    /// via the `openWindow` environment.
    static let settingsWindowID = "tomo.settings"
}

/// Menu item that opens the custom Settings window. Lives as a separate
/// `View` so it can read `@Environment(\.openWindow)` — `commands` blocks
/// are scenes and can't read view environment values directly.
private struct OpenSettingsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            openWindow(id: TomoApp.settingsWindowID)
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

/// Help menu contents. Replaces the default "Tomo Help" item (no help
/// bundle exists) with the two real channels: mail and GitHub issues.
private struct FeedbackMenuItems: View {
    private static let feedbackEmail = URL(string: "mailto:feedback@tomolibrary.com?subject=Tomo%20Feedback")!
    private static let issuesURL = URL(string: "https://github.com/pdrbrnd/tomo/issues/new")!

    var body: some View {
        Button("Send Feedback…") {
            NSWorkspace.shared.open(Self.feedbackEmail)
        }
        Button("Report an Issue on GitHub") {
            NSWorkspace.shared.open(Self.issuesURL)
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
