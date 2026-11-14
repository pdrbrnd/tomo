import Foundation
import os

/// MTP Kindle driver — Kindles from 2024 on (Paperwhite 12th gen, Colorsoft,
/// Kindle 11th gen refresh, Scribe) connect over MTP only and never mount a
/// volume. Same delivery behaviour as the volume `Kindle` driver (formats,
/// EPUB→AZW3 conversion, system-file hiding, home-screen thumbnail) via
/// `KindleDelivery`; only the transport differs.
///
/// Every operation opens its own short MTP session (`MTPConnection`), so
/// nothing is held open between calls and the device is always safe to
/// unplug. `eject()` unconfigures the USB device so the Kindle leaves its
/// "connected to computer" screen.
nonisolated struct KindleMTP: BookDevice {
    /// USB serial number — stable across reconnects.
    let serial: String

    var id: String { "mtp:\(serial)" }
    var displayName: String { "Kindle" }
    var supportedFormats: Set<String> { KindleDelivery.supportedFormats }

    /// IORegistry lookup only — doesn't open the device.
    static func detect() -> KindleMTP? {
        MTPConnection.connectedKindles().first.map { KindleMTP(serial: $0.serial) }
    }

    func filenames() -> Set<String> {
        Set(files().map(\.name))
    }

    func files() -> [DeviceFile] {
        do {
            return try MTPConnection.withSession(serial: serial) { conn throws(MTPError) in
                try listDocuments(conn)
            }
        } catch {
            // The protocol has no error channel here; an unreadable device
            // shows as empty, so make sure the reason is in the logs.
            deliveryLogger.error(
                "kindle mtp listing failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func isSystemFile(relativePath: String) -> Bool {
        KindleDelivery.isSystemFile(relativePath: relativePath)
    }

    func copy(_ book: Book) async throws {
        let name = deviceFilename(for: book)
        let serial = serial
        let convertedFromEPUB = try await KindleDelivery.withDeliverableFile(
            for: book, route: deliveryRoute(for: book)
        ) { file in
            try await Task.detached {
                do {
                    try MTPConnection.withSession(serial: serial) { conn throws(MTPError) in
                        let (storage, documents) = try Self.documentsFolder(conn)
                        try conn.upload(file, as: name, storage: storage, parent: documents)
                    }
                } catch {
                    throw BookDeviceError.copyFailed(underlying: error)
                }
            }.value
        }
        if convertedFromEPUB {
            await writeCoverThumbnail(epubURL: book.fileURL, coverOverride: book.coverURL)
        }
    }

    func removeFile(at relativePath: String) async throws {
        let serial = serial
        do {
            try await Task.detached {
                try MTPConnection.withSession(serial: serial) { conn throws(MTPError) in
                    let (storage, documents) = try Self.documentsFolder(conn)
                    let folderPath = (relativePath as NSString).deletingLastPathComponent
                    let name = (relativePath as NSString).lastPathComponent
                    let parent = try conn.folder(at: folderPath, storage: storage, from: documents)
                    guard let file = try conn.child(named: name, storage: storage, parent: parent)
                    else { throw .notFound(relativePath) }
                    try conn.delete(file.handle)
                }
            }.value
        } catch {
            throw BookDeviceError.removeFailed(underlying: error)
        }
    }

    /// Nothing to unmount, so unconfigure the USB device instead: the Kindle
    /// leaves its "connected to computer" screen, the MTP interface goes
    /// away, and it isn't detected again until it's replugged.
    func eject() async throws {
        let serial = serial
        do {
            try await Task.detached { try MTPConnection.unconfigure(serial: serial) }.value
        } catch {
            throw BookDeviceError.ejectFailed(underlying: error)
        }
    }

    // MARK: - Private

    /// The storage holding `documents/` and the folder's handle. Resolved by
    /// name every time — object handles aren't stable across sessions.
    private static func documentsFolder(_ conn: MTPConnection) throws(MTPError) -> (
        storage: UInt32, handle: UInt32
    ) {
        for storage in try conn.storageIDs() {
            if let documents = try conn.child(
                named: "documents", storage: storage, parent: PTP.rootParent),
                documents.info.isFolder
            {
                return (storage, documents.handle)
            }
        }
        throw .notFound("documents")
    }

    /// Mirrors the volume driver's walk: recurse into on-device collection
    /// folders, skip hidden entries and `.sdr` annotation sidecars, keep only
    /// formats the scanner indexes, hide Amazon's own content.
    private func listDocuments(_ conn: MTPConnection) throws(MTPError) -> [DeviceFile] {
        let (storage, documents) = try Self.documentsFolder(conn)
        var results: [DeviceFile] = []

        func walk(_ parent: UInt32, prefix: String) throws(MTPError) {
            for object in try conn.children(storage: storage, parent: parent) {
                let name = object.info.filename
                guard !name.hasPrefix(".") else { continue }
                let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
                let ext = (name as NSString).pathExtension.lowercased()
                if object.info.isFolder {
                    if ext != "sdr" { try walk(object.handle, prefix: relative) }
                    continue
                }
                guard supportedFormats.contains(ext), !isSystemFile(relativePath: relative)
                else { continue }
                results.append(
                    DeviceFile(
                        relativePath: relative,
                        size: Int64(object.info.size),
                        modifiedAt: object.info.modified ?? .distantPast
                    ))
            }
        }

        try walk(documents, prefix: "")
        return results
    }

    /// Best-effort, like the volume driver: the book is usable without it.
    /// No `.tomo/cover-thumbnails` mirror and no restore-on-reconnect yet
    /// (`KindleSync` is volume-only), so a cover Amazon overwrites while the
    /// Kindle is online stays overwritten until the book is re-sent.
    private func writeCoverThumbnail(epubURL: URL, coverOverride: URL?) async {
        let serial = serial
        do {
            try await Task.detached {
                let manifest = try EPUBSource.read(
                    from: epubURL, coverSource: .override(coverOverride))
                guard let (filename, bytes) = KindleCoverThumbnail.thumbnail(for: manifest)
                else { return }
                try MTPConnection.withSession(serial: serial) { conn throws(MTPError) in
                    let (storage, _) = try Self.documentsFolder(conn)
                    let thumbnails = try conn.folder(
                        at: KindleCoverThumbnail.thumbnailsSubpath, storage: storage)
                    try conn.upload(bytes, as: filename, storage: storage, parent: thumbnails)
                }
                deliveryLogger.info(
                    "kindle mtp thumbnail wrote \(bytes.count) bytes to \(filename, privacy: .public)")
            }.value
        } catch {
            deliveryLogger.warning(
                "kindle mtp thumbnail write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
