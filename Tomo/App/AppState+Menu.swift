import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Imperative helpers used by the menu bar. NSOpenPanel is fine to drive
/// from the App scope (no SwiftUI focus required); the picker UIs use
/// `.fileImporter` because they're attached to a view, but the menu has
/// no view to attach to.
extension AppState {
    @MainActor
    func promptForImport() async {
        guard libraryFolder != nil else {
            showToast(.error("Choose a library folder before importing."))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = LibraryImporter.acceptedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        panel.prompt = "Import"
        guard CrashReporter.runModal(panel) == .OK else { return }
        importBooks(from: panel.urls)
    }

    @MainActor
    func promptForLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select your Tomo library folder."
        if CrashReporter.runModal(panel) == .OK, let url = panel.url {
            libraryFolder = url
        }
    }

    @MainActor
    func promptForInstallPlugin() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "js") ?? .javaScript]
        panel.prompt = "Install"
        panel.message = "Choose a plugin .js file."
        if CrashReporter.runModal(panel) == .OK, let url = panel.url {
            await installPlugin(from: url)
        }
    }

    func revealLibraryInFinder() {
        guard let libraryFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([libraryFolder])
    }

    func revealPluginsFolder() {
        guard let dir = PluginDirectory.directoryURL() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    func showInFinder(books: [Book]) {
        let urls = books.map(\.fileURL)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
