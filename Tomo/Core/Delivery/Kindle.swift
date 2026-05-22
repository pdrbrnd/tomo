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
        let docOK =
            fm.fileExists(atPath: documents.path(percentEncoded: false), isDirectory: &isDir)
            && isDir.boolValue
        let sysOK =
            fm.fileExists(atPath: system.path(percentEncoded: false), isDirectory: &isDir)
            && isDir.boolValue
        guard docOK && sysOK else { return nil }

        self.volumeURL = volumeURL
        self.firmwareVersion = Self.readFirmwareVersion(volumeURL: volumeURL)
    }

    /// Kindle's home-screen scanner ignores EPUB regardless of firmware.
    /// The renderer reads EPUB on FW 5.16+, but the scanner that builds
    /// the library list from `/documents/` only indexes Amazon-friendly
    /// formats. EPUBs are converted to AZW3 on the fly via the
    /// conversion adapter — see `Tomo/Core/Conversion/`.
    var supportedFormats: Set<String> {
        ["azw", "azw3", "mobi", "prc", "pdf", "txt"]
    }

    /// No persistent warning: EPUBs are routed through the EPUB→AZW3
    /// converter when the user drops them, so the UI doesn't need to
    /// pre-warn about format support. Surface real conversion failures
    /// at copy time instead.
    var compatibilityWarning: String? { nil }

    func filenames() -> Set<String> {
        let documents = volumeURL.appending(component: "documents")
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: documents,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        return Set(entries.map { $0.lastPathComponent })
    }

    func copy(_ book: Book) async throws {
        let dest =
            volumeURL
            .appending(component: "documents")
            .appending(component: deviceFilename(for: book))

        switch deliveryRoute(for: book) {
        case .passthrough:
            try await performCopy(from: book.fileURL, to: dest)

        case .convert(let target):
            // The route helper already verified a converter exists,
            // but we fetch it again here for the actual call. Source
            // format is guaranteed to round-trip since we just got
            // back a non-nil route.
            let sourceExt = book.fileURL.pathExtension.lowercased()
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
            try await ConversionScratch.withScratchDirectory { scratch in
                // For EPUB→AZW3, route through the EPUB-specific overload
                // so the user's on-disk cover override (or its explicit
                // removal) flows into both the AZW3 cover record and the
                // home-screen thumbnail. Other source formats keep the
                // generic registry path.
                let converted: URL
                if let epubConverter = converter as? EPUBToAZW3Converter {
                    converted = try await epubConverter.convert(
                        source: book.fileURL,
                        into: scratch,
                        coverSource: .override(book.coverURL)
                    )
                } else {
                    converted = try await converter.convert(source: book.fileURL, into: scratch)
                }
                try await self.performCopy(from: converted, to: dest)
                // Best-effort home-screen cover. Calibre's thumbnail-folder
                // approach is the reliable path on modern firmwares — EXTH 201
                // alone renders inside the book but isn't picked up by the
                // home-screen scanner. Failures are non-fatal; the book is
                // usable either way.
                if sourceFormat == .epub {
                    await self.writeKindleCoverThumbnail(
                        epubURL: book.fileURL,
                        coverOverride: book.coverURL
                    )
                }
            }

        case .none:
            throw BookDeviceError.copyFailed(
                underlying: FormatConverterError.unsupported(
                    input: book.fileURL.pathExtension.lowercased(),
                    output: .azw3
                )
            )
        }
    }

    private func performCopy(from source: URL, to dest: URL) async throws {
        try await Task.detached {
            let fm = FileManager.default
            do {
                try fm.copyItem(at: source, to: dest)
            } catch let error as NSError
                where
                error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError
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
                deliveryLogger.warning(
                    "fsync after copy failed: \(error.localizedDescription, privacy: .public)")
            }
        }.value
    }

    /// Reads the EPUB to extract its cover and computed ASIN, then writes a
    /// resized JPEG to the Kindle's `system/thumbnails/` folder. Logs and
    /// returns on any failure — the home-screen cover is a nice-to-have, not
    /// a delivery contract. `coverOverride` mirrors the conversion path: when
    /// set, the user's on-disk cover (or its explicit removal via `nil`)
    /// drives the thumbnail rather than the EPUB's embedded cover.
    private func writeKindleCoverThumbnail(epubURL: URL, coverOverride: URL?) async {
        let volumeURL = self.volumeURL
        do {
            try await Task.detached {
                let manifest = try EPUBSource.read(
                    from: epubURL,
                    coverSource: .override(coverOverride)
                )
                try KindleCoverThumbnail.write(manifest: manifest, volumeURL: volumeURL)
            }.value
        } catch {
            deliveryLogger.warning(
                "kindle thumbnail write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func remove(_ book: Book) async throws {
        let dest =
            volumeURL
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
        let url =
            volumeURL
            .appending(component: "system")
            .appending(component: "version.txt")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
