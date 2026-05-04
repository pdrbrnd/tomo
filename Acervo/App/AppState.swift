import Foundation
import Observation
import AppKit
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
    var books: [Book] = []
    var collections: [Collection] = []
    private(set) var device: (any BookDevice)?
    private(set) var deviceFilenames: Set<String> = []

    /// Number of items currently being dragged inside the app. Zero when
    /// nothing is being dragged. The device tile reads this to scale up
    /// when *any* in-app drag is active, drawing attention as a drop target.
    var inAppDragCount: Int = 0

    /// State of the most recent send-to-device operation. Drives the device
    /// tile's morphing UI (idle → sending → success/error). Cleared back to
    /// idle after a brief display.
    var deviceSendState: DeviceSendState = .idle

    private var mountObserver: NSObjectProtocol?
    private var unmountObserver: NSObjectProtocol?
    private var sendStateResetTask: Task<Void, Never>?

    init() {
        self.libraryFolder = LibraryFolder.load()
        self.profiles = LanguageProfileStore.loadBundled()
        let detected = DeviceScanner.detect()
        self.device = detected
        self.deviceFilenames = detected?.filenames() ?? []
        startVolumeMonitoring()
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
                deliveryLogger.info("copied to \(device.displayName, privacy: .public): \(book.title, privacy: .public)")
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
            deliveryLogger.info("removed from \(device.displayName, privacy: .public): \(book.title, privacy: .public)")
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
        mountObserver = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDeviceState()
            }
        }
        unmountObserver = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
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

    func importBook(from url: URL) async {
        await openIndexIfNeeded()
        guard let importer else {
            libraryLogger.error("import called without index/importer")
            return
        }
        guard let libraryFolder else {
            libraryLogger.error("import called without library folder")
            return
        }
        do {
            _ = try await importer.importBook(from: url, into: libraryFolder)
            await loadBooks()
        } catch {
            libraryLogger.error("import failed: \(error.localizedDescription, privacy: .public)")
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
            await loadBooks()
            libraryLogger.info("created collection: \(trimmed, privacy: .public)")
            return collection
        } catch {
            libraryLogger.error("create collection failed: \(error.localizedDescription, privacy: .public)")
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
            // Sidecars store the old name; re-write each affected book so the
            // on-disk truth follows the rename.
            let affectedBooks = books.filter { $0.collectionIDs.contains(id) }
            for book in affectedBooks {
                await rewriteSidecar(for: book, newCollectionIDs: book.collectionIDs)
            }
            await loadBooks()
        } catch {
            libraryLogger.error("rename collection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func deleteCollection(id: UUID) async {
        await openIndexIfNeeded()
        guard let index else { return }
        // Books that lose membership need their sidecars rewritten.
        let affectedBooks = books.filter { $0.collectionIDs.contains(id) }
        do {
            try await index.deleteCollection(id: id)
            for book in affectedBooks {
                var remaining = book.collectionIDs
                remaining.remove(id)
                await rewriteSidecar(for: book, newCollectionIDs: remaining)
            }
            await loadBooks()
        } catch {
            libraryLogger.error("delete collection failed: \(error.localizedDescription, privacy: .public)")
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
            libraryLogger.error("add to collection failed: \(error.localizedDescription, privacy: .public)")
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
            libraryLogger.error("remove from collection failed: \(error.localizedDescription, privacy: .public)")
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
        let newFileName = "cover.\(ext)"
        let newURL = bookFolder.appending(component: newFileName)
        let oldCoverURL = book.coverURL

        do {
            try await Task.detached {
                if let oldCoverURL, oldCoverURL.lastPathComponent != newFileName {
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
                   LibraryFolder.isEmpty(authorFolder) {
                    do {
                        try FileManager.default.trashItem(at: authorFolder, resultingItemURL: nil)
                    } catch {
                        libraryLogger.warning("author folder cleanup failed: \(error.localizedDescription, privacy: .public)")
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

    func rebuildIndex() async {
        await openIndexIfNeeded()
        guard let index else {
            libraryLogger.error("rebuild: no index")
            return
        }
        guard let libraryFolder else {
            libraryLogger.error("rebuild: no library folder")
            return
        }
        do {
            try await index.wipeAll()
            let folders = try await LibraryFolder.bookFolders(in: libraryFolder)
            var imported = 0
            for folder in folders {
                do {
                    let loaded = try MetadataSidecar.read(from: folder)
                    try await index.add(loaded.book)
                    // Resolve collection names from the sidecar — get-or-create
                    // lets a rebuild reconstruct collections by name without
                    // any pre-seeding step.
                    for name in loaded.collectionNames {
                        let collection = try await index.getOrCreateCollection(named: name)
                        try await index.addBook(loaded.book.id, to: collection.id)
                    }
                    imported += 1
                } catch {
                    libraryLogger.error("rebuild: skipped \(folder.path(percentEncoded: false), privacy: .public) - \(error.localizedDescription, privacy: .public)")
                }
            }
            libraryLogger.info("rebuild: indexed \(imported) of \(folders.count) folders")
            await loadBooks()
        } catch {
            libraryLogger.error("rebuild failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func openIndexIfNeeded() async {
        guard index == nil else { return }
        let opened = await Task.detached { BookIndex.open() }.value
        self.index = opened
        let bundledProfiles = self.profiles
        self.importer = opened.map { LibraryImporter(index: $0, profiles: bundledProfiles) }
    }

    #if DEBUG
    /// Toggles a `MockDevice` so the device tile UI can be exercised
    /// without an e-reader plugged in. Wired to the Debug menu in
    /// `AcervoApp`. The mock pretends a few books are already on the
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
