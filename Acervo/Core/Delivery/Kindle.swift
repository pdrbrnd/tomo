import Foundation
import os

/// USB-mass-storage Kindle driver. Identifies a Kindle volume by the presence
/// of `documents/` and `system/` directories at the volume root. Reads the
/// firmware version from `system/version.txt` for diagnostics; firmware does
/// not gate format support — Kindle's scanner has never indexed EPUB
/// regardless of firmware. See `supportedFormats`.
nonisolated struct Kindle: BookDevice {
    let volumeURL: URL
    let firmwareVersion: String?

    var id: String { volumeURL.path(percentEncoded: false) }
    var displayName: String { "Kindle" }

    /// Init returns nil if the volume doesn't look like a Kindle.
    init?(volumeURL: URL) {
        let fm = FileManager.default
        let documents = volumeURL.appending(component: "documents")
        let system = volumeURL.appending(component: "system")
        var isDir: ObjCBool = false
        let docOK = fm.fileExists(atPath: documents.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
        let sysOK = fm.fileExists(atPath: system.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
        guard docOK && sysOK else { return nil }

        self.volumeURL = volumeURL
        self.firmwareVersion = Self.readFirmwareVersion(volumeURL: volumeURL)
    }

    /// Kindle's home-screen scanner ignores EPUB regardless of firmware. The
    /// renderer reads EPUB on FW 5.16+, but the scanner that builds the
    /// library list from `/documents/` only indexes Amazon-friendly formats.
    /// Confirmed across MobileRead and Amazon docs: EPUB only enters Kindle
    /// via the server-side Send to Kindle pipeline (which converts to KFX).
    var supportedFormats: Set<String> {
        ["azw", "azw3", "mobi", "prc", "pdf", "txt"]
    }

    var compatibilityWarning: String? {
        "Kindle's home-screen scanner doesn't index sideloaded EPUBs (only AZW3, MOBI, PDF, TXT). For EPUBs, use Share → Send to Kindle so Amazon converts on its servers."
    }

    func filenames() -> Set<String> {
        let documents = volumeURL.appending(component: "documents")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return Set(entries.map { $0.lastPathComponent })
    }

    func deviceFilename(for book: Book) -> String {
        fatSafeFilename(book.fileURL.lastPathComponent)
    }

    func copy(_ book: Book) async throws {
        let sourceExt = book.fileURL.pathExtension.lowercased()
        let target = FileFormat.azw3

        // Pass-through: source format is already indexable by Kindle.
        if supportedFormats.contains(sourceExt) {
            let dest = volumeURL
                .appending(component: "documents")
                .appending(component: deviceFilename(for: book))
            try await performCopy(from: book.fileURL, to: dest)
            return
        }

        // Conversion required (e.g. EPUB → AZW3). Layer 1 ships the
        // adapter scaffolding with no converters registered, so EPUBs
        // still fail here — but loudly, with a clear message.
        guard let sourceFormat = FileFormat(rawValue: sourceExt),
              let converter = ConversionRegistry.default
                .converter(from: sourceFormat, to: target)
        else {
            throw BookDeviceError.copyFailed(
                underlying: FormatConverterError.unsupported(
                    input: sourceExt, output: target
                )
            )
        }
        let convertedFilename = fatSafeFilename(
            book.fileURL.deletingPathExtension().lastPathComponent
                + "." + target.rawValue
        )
        let dest = volumeURL
            .appending(component: "documents")
            .appending(component: convertedFilename)
        try await ConversionScratch.withScratchDirectory { scratch in
            let converted = try await converter.convert(source: book.fileURL, into: scratch)
            try await self.performCopy(from: converted, to: dest)
        }
    }

    private func performCopy(from source: URL, to dest: URL) async throws {
        try await Task.detached {
            let fm = FileManager.default
            do {
                try fm.copyItem(at: source, to: dest)
            } catch let error as NSError where
                error.domain == NSCocoaErrorDomain &&
                error.code == NSFileWriteFileExistsError
            {
                throw BookDeviceError.alreadyOnDevice
            } catch {
                throw BookDeviceError.copyFailed(underlying: error)
            }
            // fsync — macOS lazy-flushes; without this the eject can race the write.
            do {
                let handle = try FileHandle(forUpdating: dest)
                try handle.synchronize()
                try handle.close()
            } catch {
                deliveryLogger.warning("fsync after copy failed: \(error.localizedDescription, privacy: .public)")
            }
        }.value
    }

    func remove(_ book: Book) async throws {
        let dest = volumeURL
            .appending(component: "documents")
            .appending(component: deviceFilename(for: book))
        do {
            try await Task.detached {
                try FileManager.default.removeItem(at: dest)
            }.value
        } catch {
            throw BookDeviceError.removeFailed(underlying: error)
        }
    }

    func eject() async throws {
        try await ejectVolume(volumeURL)
    }

    // MARK: - Firmware

    private static func readFirmwareVersion(volumeURL: URL) -> String? {
        let url = volumeURL
            .appending(component: "system")
            .appending(component: "version.txt")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
