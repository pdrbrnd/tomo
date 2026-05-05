import AppKit
import Foundation
import Observation
import os

private nonisolated func pngData(from image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff)
    else { return nil }
    return bitmap.representation(using: .png, properties: [:])
}

/// Drives the device tile's morphing UI for the send-to-device flow.
/// Distinct from the drag-active scale-up: this only covers the post-drop
/// progress + success/failure stretch.
enum DeviceSendState: Equatable {
    case idle
    case sending(completed: Int, total: Int)
    case success(count: Int)
    case error(String)
}

@Observable
final class AppState {
    var libraryFolder: URL? {
        didSet { LibraryFolder.save(libraryFolder) }
    }
    private(set) var index: BookIndex?
    private(set) var importer: LibraryImporter?
    let profiles: [LanguageProfile]
    var books: [Book] = [] {
        didSet { recomputeCounts() }
    }
    var collections: [Collection] = []
    private(set) var device: (any BookDevice)?
    private(set) var deviceFilenames: Set<String> = []

    /// Number of books in each collection. Cached from `books`; cheaper than
    /// recomputing in every `LibrarySidebar` body evaluation.
    private(set) var collectionCounts: [UUID: Int] = [:]

    /// Number of books per locale tag. Same caching rationale as above.
    private(set) var languageCounts: [String: Int] = [:]

    private func recomputeCounts() {
        var coll: [UUID: Int] = [:]
        for book in books {
            for cid in book.collectionIDs {
                coll[cid, default: 0] += 1
            }
        }
        collectionCounts = coll
        languageCounts = Dictionary(grouping: books, by: \.locale).mapValues(\.count)
    }

    /// Number of items currently being dragged inside the app. Zero when
    /// nothing is being dragged. The device tile reads this to scale up
    /// when *any* in-app drag is active, drawing attention as a drop target.
    var inAppDragCount: Int = 0

    /// State of the most recent send-to-device operation. Drives the device
    /// tile's morphing UI (idle → sending → success/error). Cleared back to
    /// idle after a brief display.
    var deviceSendState: DeviceSendState = .idle

    /// Currently visible toast, or nil when nothing is shown. Replaced on
    /// every `showToast` call (no stacking). Auto-dismissed by a task; the
    /// task is cancelled when superseded by a new toast.
    var currentToast: Toast?

    /// User-loaded JS plugins used as search sources. All `.js` files in the
    /// plugins directory; replaced wholesale on reload. Empty until
    /// `loadPluginsIfPresent()` runs.
    private(set) var pluginSources: [PluginSource] = []

    /// IDs of plugins currently enabled for search. Persisted in
    /// `UserDefaults` under `enabledPluginIDs`. First-run default: all
    /// loaded plugins are enabled.
    private(set) var enabledPluginIDs: Set<String> = []

    /// Plugins currently enabled for search.
    var enabledPlugins: [PluginSource] {
        pluginSources.filter { enabledPluginIDs.contains($0.id) }
    }

    /// Looks up a loaded plugin by ID. Used to route a `PluginResult`'s
    /// download call back to the plugin that produced it.
    func plugin(withID id: String) -> PluginSource? {
        pluginSources.first(where: { $0.id == id })
    }

    private static let enabledPluginIDsKey = "enabledPluginIDs"
    private static let didInitPluginEnableStateKey = "didInitPluginEnableState"

    /// True while a plugin search is in flight (post-debounce, awaiting
    /// the plugin's `search()` Promise). Drives the trailing-icon spinner
    /// and the "searching…" empty state.
    var pluginSearchInFlight: Bool = false

    private nonisolated(unsafe) var mountTask: Task<Void, Never>?
    private nonisolated(unsafe) var unmountTask: Task<Void, Never>?
    private var sendStateResetTask: Task<Void, Never>?
    private var toastDismissTask: Task<Void, Never>?

    init() {
        self.libraryFolder = LibraryFolder.load()
        self.profiles = LanguageProfileStore.loadBundled()
        let detected = DeviceScanner.detect()
        self.device = detected
        self.deviceFilenames = detected?.filenames() ?? []
        startVolumeMonitoring()
        if let stored = UserDefaults.standard.array(forKey: Self.enabledPluginIDsKey) as? [String] {
            self.enabledPluginIDs = Set(stored)
        }
        PluginDirectory.seedBundledPluginsIfNeeded()
        loadPluginsIfPresent()
        // First-run for the per-plugin toggle: enable everything that loaded
        // so the user gets working search out of the box without a tour.
        if !UserDefaults.standard.bool(forKey: Self.didInitPluginEnableStateKey) {
            self.enabledPluginIDs = Set(pluginSources.map(\.id))
            persistEnabledPluginIDs()
            UserDefaults.standard.set(true, forKey: Self.didInitPluginEnableStateKey)
        }
    }

    private func persistEnabledPluginIDs() {
        UserDefaults.standard.set(Array(enabledPluginIDs), forKey: Self.enabledPluginIDsKey)
    }

    /// Per-plugin enable toggle from the sources popover. Persisted.
    func setPluginEnabled(_ pluginID: String, enabled: Bool) {
        if enabled { enabledPluginIDs.insert(pluginID) } else { enabledPluginIDs.remove(pluginID) }
        persistEnabledPluginIDs()
    }

    /// Loads every plugin in the plugins directory. Folder is source of
    /// truth — rename / delete on disk takes effect on the next reload.
    /// One broken plugin doesn't prevent others from loading; the first
    /// error surfaces as a toast.
    ///
    /// Note: replacing `pluginSources` doesn't actively cancel in-flight
    /// `fetch` Tasks owned by prior `PluginHost`s. Those Tasks hop back to
    /// MainActor and call `resolve`/`reject` on JSValues whose contexts
    /// have been replaced — harmless (the resolved value is discarded by
    /// an abandoned Promise) but worth knowing. Productionisation should
    /// track in-flight tasks per host and cancel on reload.
    private func loadPluginsIfPresent() {
        let result = PluginDirectory.loadAllPlugins()
        self.pluginSources = result.plugins
        // Drop enabled IDs whose plugin file is gone so the set stays
        // tight to actually-loaded plugins.
        let loadedIDs = Set(result.plugins.map(\.id))
        if !enabledPluginIDs.isSubset(of: loadedIDs) {
            enabledPluginIDs.formIntersection(loadedIDs)
            persistEnabledPluginIDs()
        }
        pluginLogger.info("loaded \(result.plugins.count, privacy: .public) plugin(s)")
        if let err = result.firstError {
            showToast(.error("Plugin failed to load: \(err.localizedDescription)"))
        }
    }

    /// Re-runs plugin loading. Call after the user adds or removes a plugin
    /// file in the plugins directory.
    func reloadPluginSource() {
        loadPluginsIfPresent()
    }

    /// Copies a user-chosen `.js` into the plugins directory, preserving the
    /// source filename. Existing files of the same name are overwritten.
    /// Reloads after copying so the new plugin shows up immediately.
    func installPlugin(from sourceURL: URL) async {
        guard let dir = PluginDirectory.directoryURL() else {
            showToast(.error("Couldn't locate plugins directory."))
            return
        }
        let destURL = dir.appending(path: sourceURL.lastPathComponent)
        do {
            try await Task.detached {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destURL.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
            }.value
            let installedID = sourceURL.deletingPathExtension().lastPathComponent
            reloadPluginSource()
            if let installed = plugin(withID: installedID) {
                // Newly installed plugins start enabled. Existing plugins
                // overwritten by the same name keep whatever state they had.
                if !enabledPluginIDs.contains(installed.id) {
                    setPluginEnabled(installed.id, enabled: true)
                }
                showToast(.info("Plugin installed."))
            }
        } catch {
            pluginLogger.error("install plugin failed: \(error.localizedDescription, privacy: .public)")
            showToast(.error("Couldn't install plugin: \(error.localizedDescription)"))
        }
    }

    /// Replaces any current toast with `toast` and schedules its auto-dismiss.
    /// The previous dismiss task is cancelled so the new toast lives its full
    /// duration, even if it arrives before the old one would have expired.
    func showToast(_ toast: Toast) {
        toastDismissTask?.cancel()
        currentToast = toast
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: toast.dismissAfter)
            guard !Task.isCancelled else { return }
            // Only clear if this toast is still the active one.
            if self?.currentToast?.id == toast.id {
                self?.currentToast = nil
            }
        }
    }

    nonisolated deinit {
        mountTask?.cancel()
        unmountTask?.cancel()
    }

    func sendToDevice(book: Book) async {
        await sendBooksToDevice([book])
    }

    /// Sequentially copies books to the connected device, driving
    /// `deviceSendState` so the tile can morph through sending → success/error.
    /// Books that the device can't accept are filtered out before sending.
    func sendBooksToDevice(_ books: [Book]) async {
        guard let device else {
            deliveryLogger.error("send to device: no device connected")
            return
        }
        let toSend = books.filter { device.canAccept($0) }
        guard !toSend.isEmpty else { return }

        sendStateResetTask?.cancel()
        deviceSendState = .sending(completed: 0, total: toSend.count)

        var successes = 0
        var lastError: Error?
        for (index, book) in toSend.enumerated() {
            do {
                try await device.copy(book)
                successes += 1
                deliveryLogger.info(
                    "copied to \(device.displayName, privacy: .public): \(book.title, privacy: .public)")
                deviceSendState = .sending(completed: index + 1, total: toSend.count)
            } catch {
                lastError = error
                deliveryLogger.error("device copy failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        deviceFilenames = device.filenames()

        if let lastError, successes == 0 {
            deviceSendState = .error(lastError.localizedDescription)
        } else {
            deviceSendState = .success(count: successes)
        }

        sendStateResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.deviceSendState = .idle
        }
    }

    /// Bulk trash. Each delete runs independently; failures are logged
    /// (in `deleteBook`) but don't halt the loop. Partial-success is
    /// surfaced through the on-disk truth (loadBooks reflects what's left).
    func deleteBooks(_ books: [Book]) async {
        for book in books {
            await deleteBook(book)
        }
    }

    func removeFromDevice(book: Book) async {
        guard let device else { return }
        do {
            try await device.remove(book)
            deliveryLogger.info(
                "removed from \(device.displayName, privacy: .public): \(book.title, privacy: .public)")
            deviceFilenames = device.filenames()
        } catch {
            deliveryLogger.error("device remove failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func ejectDevice() async {
        guard let device else { return }
        do {
            try await device.eject()
            deliveryLogger.info("ejected device: \(device.displayName, privacy: .public)")
            // The unmount notification clears `device` and `deviceFilenames`.
        } catch {
            deliveryLogger.error("eject failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startVolumeMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        mountTask = Task { @MainActor [weak self] in
            for await _ in center.notifications(named: NSWorkspace.didMountNotification) {
                self?.refreshDeviceState()
            }
        }
        unmountTask = Task { @MainActor [weak self] in
            for await _ in center.notifications(named: NSWorkspace.didUnmountNotification) {
                self?.refreshDeviceState()
            }
        }
    }

    private func refreshDeviceState() {
        let detected = DeviceScanner.detect()
        device = detected
        deviceFilenames = detected?.filenames() ?? []
    }

    func loadBooks() async {
        await openIndexIfNeeded()
        guard let index else { return }
        do {
            async let booksTask = index.all()
            async let collectionsTask = index.collections()
            self.books = try await booksTask
            self.collections = try await collectionsTask
        } catch {
            libraryLogger.error("load books failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Maps `Book.collectionIDs` to the collection *names* — what the sidecar
    /// stores. Sorted for stable serialisation.
    private func collectionNames(for ids: Set<UUID>) -> [String] {
        collections
            .filter { ids.contains($0.id) }
            .map(\.name)
            .sorted()
    }

    /// Imports a file into the library and returns the resulting `Book`.
    /// Returns nil on failure and surfaces a toast to the user. Callers
    /// that don't need the imported book can ignore the return value —
    /// the standard refresh still happens.
    @discardableResult
    func importBook(from url: URL) async -> Book? {
        await openIndexIfNeeded()
        guard let importer else {
            libraryLogger.error("import called without index/importer")
            showToast(.error("Library isn't ready yet."))
            return nil
        }
        guard let libraryFolder else {
            libraryLogger.error("import called without library folder")
            showToast(.error("Choose a library folder before importing."))
            return nil
        }
        do {
            let imported = try await importer.importBook(from: url, into: libraryFolder)
            await loadBooks()
            return imported
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            showToast(.error("\(url.lastPathComponent): \(message)"))
            libraryLogger.error("import failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func updateBook(_ book: Book) async {
        await openIndexIfNeeded()
        guard let index else {
            libraryLogger.error("update: no index")
            return
        }
        let bookFolder = book.fileURL.deletingLastPathComponent()
        let bookForSidecar = book
        let names = collectionNames(for: book.collectionIDs)
        do {
            try await Task.detached {
                try MetadataSidecar.write(bookForSidecar, collectionNames: names, to: bookFolder)
            }.value
            try await index.update(book)
            await loadBooks()
            libraryLogger.info("updated: \(book.title, privacy: .public)")
        } catch {
            libraryLogger.error("update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Collections

    @discardableResult
    func createCollection(named name: String) async -> Collection? {
        await openIndexIfNeeded()
        guard let index else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let collection = try await index.createCollection(named: trimmed)
            await persistCollectionsToDisk()
            await loadBooks()
            libraryLogger.info("created collection: \(trimmed, privacy: .public)")
            return collection
        } catch {
            libraryLogger.error(
                "create collection failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func renameCollection(id: UUID, to newName: String) async {
        await openIndexIfNeeded()
        guard let index else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await index.renameCollection(id: id, to: trimmed)
            await persistCollectionsToDisk()
            // Sidecars store the old name; re-write each affected book so the
            // on-disk truth follows the rename.
            let affectedBooks = books.filter { $0.collectionIDs.contains(id) }
            for book in affectedBooks {
                await rewriteSidecar(for: book, newCollectionIDs: book.collectionIDs)
            }
            await loadBooks()
        } catch {
            libraryLogger.error(
                "rename collection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func deleteCollection(id: UUID) async {
        await openIndexIfNeeded()
        guard let index else { return }
        // Books that lose membership need their sidecars rewritten.
        let affectedBooks = books.filter { $0.collectionIDs.contains(id) }
        do {
            try await index.deleteCollection(id: id)
            await persistCollectionsToDisk()
            for book in affectedBooks {
                var remaining = book.collectionIDs
                remaining.remove(id)
                await rewriteSidecar(for: book, newCollectionIDs: remaining)
            }
            await loadBooks()
        } catch {
            libraryLogger.error(
                "delete collection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Snapshots the index's current collection definitions to
    /// `<library>/.tomo/collections.json`. Called after any mutation that
    /// changes the collection set (create / rename / delete) and at the end
    /// of a disk sync to capture sidecar-driven auto-creations.
    private func persistCollectionsToDisk() async {
        guard let libraryFolder, let index else { return }
        do {
            let collections = try await index.collections()
            try await Task.detached { [libraryFolder] in
                try CollectionsFile.write(collections, in: libraryFolder)
            }.value
        } catch {
            libraryLogger.error(
                "persist collections.json failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func addBook(_ book: Book, to collectionID: UUID) async {
        await openIndexIfNeeded()
        guard let index else { return }
        guard !book.collectionIDs.contains(collectionID) else { return }
        do {
            try await index.addBook(book.id, to: collectionID)
            var newIDs = book.collectionIDs
            newIDs.insert(collectionID)
            await rewriteSidecar(for: book, newCollectionIDs: newIDs)
            await loadBooks()
        } catch {
            libraryLogger.error(
                "add to collection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func removeBook(_ book: Book, from collectionID: UUID) async {
        await openIndexIfNeeded()
        guard let index else { return }
        guard book.collectionIDs.contains(collectionID) else { return }
        do {
            try await index.removeBook(book.id, from: collectionID)
            var newIDs = book.collectionIDs
            newIDs.remove(collectionID)
            await rewriteSidecar(for: book, newCollectionIDs: newIDs)
            await loadBooks()
        } catch {
            libraryLogger.error(
                "remove from collection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-writes a book's sidecar with an updated collection-membership set.
    /// Membership is mirrored to disk so a rebuild from sidecars reconstructs
    /// the same groupings.
    private func rewriteSidecar(for book: Book, newCollectionIDs: Set<UUID>) async {
        let bookFolder = book.fileURL.deletingLastPathComponent()
        let names = collectionNames(for: newCollectionIDs)
        let bookForSidecar = book
        do {
            try await Task.detached {
                try MetadataSidecar.write(bookForSidecar, collectionNames: names, to: bookFolder)
            }.value
        } catch {
            libraryLogger.error("sidecar rewrite failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setCover(for book: Book, fromFile url: URL) async {
        let ext = url.pathExtension.lowercased().isEmpty ? "jpg" : url.pathExtension.lowercased()
        do {
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            await writeCover(data, ext: ext, for: book)
        } catch {
            libraryLogger.error("cover read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setCover(for book: Book, image: NSImage) async {
        guard let data = pngData(from: image) else {
            libraryLogger.error("cover encode to PNG failed")
            return
        }
        await writeCover(data, ext: "png", for: book)
    }

    /// Direct write path for cover bytes we already hold (e.g. JPEG fetched
    /// from Open Library / Google Books). Skips the NSImage→PNG round-trip
    /// — both because it preserves the source's quality and because
    /// `NSImage(data:)` from a JPEG often surfaces no `tiffRepresentation`
    /// until forced, which makes `pngData` silently nil.
    func setCover(for book: Book, fromData data: Data, ext: String) async {
        let normalised = ext.lowercased().isEmpty ? "jpg" : ext.lowercased()
        await writeCover(data, ext: normalised, for: book)
    }

    func removeCover(for book: Book) async {
        if let coverURL = book.coverURL {
            try? await Task.detached {
                try FileManager.default.removeItem(at: coverURL)
            }.value
        }
        var updated = book
        updated.coverPath = nil
        await updateBook(updated)
    }

    private func writeCover(_ data: Data, ext: String, for book: Book) async {
        let bookFolder = book.fileURL.deletingLastPathComponent()
        // Unique-per-save filename. Same path + same name = identical `URL`,
        // and SwiftUI's view diffing then skips re-evaluating any
        // `LocalCoverImage` body — so the cached `@State image` would stay
        // even though the bytes on disk just changed. A unique URL per save
        // is the natural change-signal that propagates through the parent
        // view tree without bespoke notifications.
        let suffix = String(UUID().uuidString.prefix(6).lowercased())
        let newFileName = "cover-\(suffix).\(ext)"
        let newURL = bookFolder.appending(component: newFileName)
        let oldCoverURL = book.coverURL

        do {
            try await Task.detached {
                if let oldCoverURL {
                    try? FileManager.default.removeItem(at: oldCoverURL)
                }
                try data.write(to: newURL, options: .atomic)
            }.value
        } catch {
            libraryLogger.error("cover write failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        var updated = book
        updated.coverPath = newFileName
        await updateBook(updated)
    }

    func deleteBook(_ book: Book) async {
        await openIndexIfNeeded()
        guard let index else {
            libraryLogger.error("delete: no index")
            return
        }
        let bookFolder = book.fileURL.deletingLastPathComponent()
        let authorFolder = bookFolder.deletingLastPathComponent()
        let libFolder = libraryFolder
        do {
            try await Task.detached {
                try FileManager.default.trashItem(at: bookFolder, resultingItemURL: nil)
                // Best-effort cleanup of now-empty author folder. Never trash the
                // library folder itself, even if it's empty.
                if let libFolder,
                    authorFolder.standardizedFileURL != libFolder.standardizedFileURL,
                    LibraryFolder.isEmpty(authorFolder)
                {
                    do {
                        try FileManager.default.trashItem(at: authorFolder, resultingItemURL: nil)
                    } catch {
                        libraryLogger.warning(
                            "author folder cleanup failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }.value
            try await index.delete(book)
            await loadBooks()
            libraryLogger.info("trashed: \(book.title, privacy: .public)")
        } catch {
            libraryLogger.error("delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reconciles the index with the on-disk library: adds sidecars not yet
    /// indexed, removes index rows whose folders are gone, resolves collection
    /// memberships from sidecars. Idempotent and additive — safe to call on
    /// every appear and every library-folder change.
    ///
    /// This is how the disk-truth principle is enforced at runtime. The index
    /// is disposable; the library is the source of truth. A second machine
    /// pointed at the same iCloud folder, a fresh install, a deleted DB —
    /// they all rebuild themselves through here without user action.
    func syncWithDisk() async {
        await openIndexIfNeeded()
        guard let index else { return }
        guard let libraryFolder else {
            // No folder set: just refresh the UI from whatever's in the index.
            // The grid placeholder ("Open Settings…") handles the empty case.
            await loadBooks()
            return
        }
        do {
            // 1. One-time migration: if no collections.json exists yet but the
            //    DB has collections (carried forward from before this change),
            //    dump them to disk so we don't lose UUIDs / sortOrder. Runs
            //    only on first sync after upgrade.
            let didMigrate = try await migrateLegacyCollectionsIfNeeded(
                in: libraryFolder, index: index)

            // 2. Read collection definitions from disk and seed the index
            //    (wipes previous library's collections — fixes the
            //    ghost-collection bug on library-folder change). nil =
            //    fresh library with no JSON yet.
            let onDiskCollections =
                try await Task.detached { [libraryFolder] in
                    try CollectionsFile.read(in: libraryFolder)
                }.value
            try await index.seedCollections(onDiskCollections ?? [])

            // 3. Walk the library folder, read sidecars.
            let folders = try await LibraryFolder.bookFolders(in: libraryFolder)
            var sidecars: [LoadedSidecar] = []
            for folder in folders {
                try Task.checkCancellation()
                do {
                    sidecars.append(try MetadataSidecar.read(from: folder))
                } catch {
                    libraryLogger.error(
                        "sync: skipped \(folder.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            let onDisk = Set(sidecars.map(\.book.id))
            let inIndex = try await index.allIDs()
            let toAdd = onDisk.subtracting(inIndex)
            let orphans = inIndex.subtracting(onDisk)

            for id in orphans {
                try Task.checkCancellation()
                try await index.delete(id: id)
            }

            // 4. Re-attach memberships for ALL sidecars (not just new ones),
            //    since we just wiped book_collections in step 2.
            for sidecar in sidecars {
                try Task.checkCancellation()
                if toAdd.contains(sidecar.book.id) {
                    try await index.add(sidecar.book)
                }
                for name in sidecar.collectionNames {
                    // getOrCreate so a sidecar referencing a not-yet-on-disk
                    // collection still resolves. New collections are picked
                    // up in the persist step below.
                    let collection = try await index.getOrCreateCollection(named: name)
                    try await index.addBook(sidecar.book.id, to: collection.id)
                }
            }

            // 5. If a sidecar auto-created a collection in step 4, it's now
            //    in the DB but not on disk. Snapshot the DB to JSON so disk
            //    catches up. Skipped when migration already wrote the file.
            if !didMigrate {
                await persistCollectionsToDisk()
            }

            libraryLogger.info(
                "sync: \(sidecars.count) on disk, +\(toAdd.count) -\(orphans.count)")
            await loadBooks()
        } catch is CancellationError {
            libraryLogger.info("sync cancelled")
        } catch {
            libraryLogger.error("sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let didMigrateLegacyCollectionsKey = "didMigrateLegacyCollections"

    /// One-time migration: pre-v1, collection definitions only existed in the
    /// SQLite index. Post-v1 they live in `<library>/.tomo/collections.json`.
    /// On the very first sync after upgrade, dump the index's collections to
    /// the current library's JSON so UUIDs / sortOrder survive. Gated by a
    /// `UserDefaults` flag so it can't fire again — critical, otherwise
    /// switching to a fresh library folder would re-migrate the *previous*
    /// library's stale DB rows into the new folder's JSON. Returns true if
    /// the file was written.
    private func migrateLegacyCollectionsIfNeeded(
        in libraryFolder: URL, index: BookIndex
    ) async throws -> Bool {
        guard !UserDefaults.standard.bool(forKey: Self.didMigrateLegacyCollectionsKey) else {
            return false
        }
        defer { UserDefaults.standard.set(true, forKey: Self.didMigrateLegacyCollectionsKey) }
        let exists = await Task.detached { [libraryFolder] in
            CollectionsFile.exists(in: libraryFolder)
        }.value
        guard !exists else { return false }
        let dbCollections = try await index.collections()
        guard !dbCollections.isEmpty else { return false }
        try await Task.detached { [libraryFolder] in
            try CollectionsFile.write(dbCollections, in: libraryFolder)
        }.value
        libraryLogger.info(
            "migrated \(dbCollections.count, privacy: .public) collection(s) → collections.json")
        return true
    }

    private func openIndexIfNeeded() async {
        guard index == nil else { return }
        do {
            let opened = try await Task.detached { try BookIndex() }.value
            self.index = opened
            self.importer = LibraryImporter(index: opened, profiles: self.profiles)
        } catch {
            indexLogger.error("failed to open index: \(error.localizedDescription, privacy: .public)")
        }
    }

    #if DEBUG
        /// Toggles a `MockDevice` so the device tile UI can be exercised
        /// without an e-reader plugged in. Wired to the Debug menu in
        /// `TomoApp`. The mock pretends a few books are already on the
        /// device too, so the on-device check badge / dim states render.
        func toggleFakeDevice() {
            if device is MockDevice {
                device = nil
                deviceFilenames = []
                deviceSendState = .idle
            } else {
                // Pretend the first ~half of the library is already on the
                // device so card states (check badge + dimmed missing) read
                // visibly differently.
                let half = books.prefix(books.count / 2)
                let pretendOnDevice = Set(half.map { fatSafeFilename($0.fileURL.lastPathComponent) })
                let mock = MockDevice(mockFilenames: pretendOnDevice)
                device = mock
                deviceFilenames = pretendOnDevice
            }
        }

        /// Cycles the device send state through its non-idle visuals so the
        /// device tile's morph (sending → success → error) can be inspected
        /// without actually copying files.
        func cycleFakeSendState() {
            switch deviceSendState {
            case .idle:
                deviceSendState = .sending(completed: 1, total: 3)
            case .sending(let completed, let total) where completed < total:
                deviceSendState = .sending(completed: completed + 1, total: total)
            case .sending:
                deviceSendState = .success(count: 3)
            case .success:
                deviceSendState = .error("Test error")
            case .error:
                deviceSendState = .idle
            }
        }
    #endif
}
