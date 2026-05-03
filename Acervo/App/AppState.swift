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
            self.books = try await index.all()
        } catch {
            libraryLogger.error("load books failed: \(error.localizedDescription, privacy: .public)")
        }
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
        do {
            try await Task.detached {
                try MetadataSidecar.write(bookForSidecar, to: bookFolder)
            }.value
            try await index.update(book)
            await loadBooks()
            libraryLogger.info("updated: \(book.title, privacy: .public)")
        } catch {
            libraryLogger.error("update failed: \(error.localizedDescription, privacy: .public)")
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
                    let book = try MetadataSidecar.read(from: folder)
                    try await index.add(book)
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
}
