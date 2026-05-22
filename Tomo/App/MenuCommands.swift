import SwiftUI

/// Snapshot of library-window state that the menu bar reads to enable,
/// disable, and dynamically-label menu items. Republished on every body
/// evaluation in `LibraryView` via `.focusedSceneValue(\.libraryContext, …)`.
///
/// Closures capture the view's current state and AppState reference, so
/// firing them from a menu item runs the same code as the in-window
/// affordance — no parallel implementations to drift.
struct LibraryFocusContext {
    var hasSelection: Bool
    var selectionCount: Int
    var deviceName: String?
    var canSendSelection: Bool
    var canRemoveSelectionFromDevice: Bool
    var hasDevice: Bool
    var isSidebarOpen: Bool
    var isInspectorOpen: Bool
    var sortKey: BookSort
    var sortAscending: Bool

    var showSelectedInFinder: () -> Void
    var moveSelectedToTrash: () -> Void
    var sendSelectedToDevice: () -> Void
    var removeSelectedFromDevice: () -> Void
    var focusSearch: () -> Void
    var beginNewCollection: () -> Void
    var toggleSidebar: () -> Void
    var toggleInspector: () -> Void
    var setSortKey: (BookSort) -> Void
    var setSortAscending: (Bool) -> Void
}

private struct LibraryFocusKey: FocusedValueKey {
    typealias Value = LibraryFocusContext
}

extension FocusedValues {
    var libraryContext: LibraryFocusContext? {
        get { self[LibraryFocusKey.self] }
        set { self[LibraryFocusKey.self] = newValue }
    }
}

// MARK: - Commands

/// The library menu bar. Split into one `Commands` struct per top-level
/// menu so each can pull its own `@FocusedValue` slice without re-reading
/// the whole context everywhere.
struct LibraryMenuCommands: Commands {
    let state: AppState

    var body: some Commands {
        FileMenuCommands(state: state)
        EditMenuCommands()
        ViewMenuCommands()
        LibraryMenuLibraryMenu(state: state)
    }
}

private struct FileMenuCommands: Commands {
    let state: AppState
    @FocusedValue(\.libraryContext) private var ctx

    var body: some Commands {
        // Replace the default "New" group so we own ⌘N / ⌘O without
        // colliding with SwiftUI's stock items for document-based apps.
        CommandGroup(replacing: .newItem) {
            Button("Import…") {
                Task { await state.promptForImport() }
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(state.libraryFolder == nil)

            Button("New Collection…") {
                ctx?.beginNewCollection()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(ctx == nil || state.libraryFolder == nil)

            Divider()

            Button("Choose Library Folder…") {
                state.promptForLibraryFolder()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button("Show Library in Finder") {
                state.revealLibraryInFinder()
            }
            .disabled(state.libraryFolder == nil)

            Divider()

            Button(showInFinderLabel) {
                ctx?.showSelectedInFinder()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(ctx?.hasSelection != true)

            Button(moveToTrashLabel) {
                ctx?.moveSelectedToTrash()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(ctx?.hasSelection != true)
        }
    }

    private var showInFinderLabel: String {
        let count = ctx?.selectionCount ?? 0
        return count > 1 ? "Show \(count) in Finder" : "Show in Finder"
    }

    private var moveToTrashLabel: String {
        let count = ctx?.selectionCount ?? 0
        return count > 1 ? "Move \(count) to Trash…" : "Move to Trash…"
    }
}

private struct EditMenuCommands: Commands {
    @FocusedValue(\.libraryContext) private var ctx

    var body: some Commands {
        // Stock textEditing group has Find / Find Next / Find Previous /
        // Use Selection for Find / Jump to Selection — most of which we
        // don't wire. Replace with the one item we actually support so the
        // menu doesn't list dead shortcuts.
        CommandGroup(replacing: .textEditing) {
            Button("Find") {
                ctx?.focusSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(ctx == nil)
        }
    }
}

private struct ViewMenuCommands: Commands {
    @FocusedValue(\.libraryContext) private var ctx

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button(sidebarLabel) {
                ctx?.toggleSidebar()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(ctx == nil)

            Button(inspectorLabel) {
                ctx?.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(ctx == nil)

            Divider()

            Menu("Sort By") {
                // Inline Picker renders each option as a menu item with a
                // checkmark on the current choice — standard macOS behaviour
                // for radio-style menu groups. `labelsHidden` suppresses the
                // Picker's own label from appearing as a header above the
                // items so we get a clean Finder-style list.
                Picker(
                    selection: Binding(
                        get: { ctx?.sortKey ?? .title },
                        set: { ctx?.setSortKey($0) }
                    )
                ) {
                    ForEach(BookSort.allCases) { option in
                        Text(option.label).tag(option)
                    }
                } label: {
                    Text("Sort key")
                }
                .pickerStyle(.inline)
                .labelsHidden()

                Divider()

                Picker(
                    selection: Binding(
                        get: { ctx?.sortAscending ?? true },
                        set: { ctx?.setSortAscending($0) }
                    )
                ) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                } label: {
                    Text("Direction")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .disabled(ctx == nil)
        }
    }

    private var sidebarLabel: String {
        (ctx?.isSidebarOpen == true) ? "Hide Sidebar" : "Show Sidebar"
    }

    private var inspectorLabel: String {
        (ctx?.isInspectorOpen == true) ? "Hide Details" : "Show Details"
    }
}

/// The "Library" top-level menu. Named `LibraryMenuLibraryMenu` to avoid
/// colliding with the outer `LibraryMenuCommands` umbrella.
private struct LibraryMenuLibraryMenu: Commands {
    let state: AppState
    @FocusedValue(\.libraryContext) private var ctx

    var body: some Commands {
        CommandMenu("Library") {
            Button(sendLabel) {
                ctx?.sendSelectedToDevice()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(ctx?.canSendSelection != true)

            Button(removeLabel) {
                ctx?.removeSelectedFromDevice()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(ctx?.canRemoveSelectionFromDevice != true)

            Button(ejectLabel) {
                Task { await state.ejectDevice() }
            }
            .disabled(ctx?.hasDevice != true)

            Divider()

            Button("Install Plugin…") {
                Task { await state.promptForInstallPlugin() }
            }

            Button("Reveal Plugins Folder") {
                state.revealPluginsFolder()
            }

            Button("Reload Plugins") {
                state.reloadPluginSource()
            }
        }
    }

    private var deviceName: String { ctx?.deviceName ?? "Kindle" }

    private var sendLabel: String {
        let count = ctx?.selectionCount ?? 0
        return count > 1 ? "Send \(count) to \(deviceName)" : "Send to \(deviceName)"
    }

    private var removeLabel: String {
        let count = ctx?.selectionCount ?? 0
        return count > 1 ? "Remove \(count) from \(deviceName)" : "Remove from \(deviceName)"
    }

    private var ejectLabel: String {
        guard ctx?.hasDevice == true else { return "Eject Device" }
        return "Eject \(deviceName)"
    }
}
