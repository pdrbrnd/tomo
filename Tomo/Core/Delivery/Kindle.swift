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

    func filenames() -> Set<String> {
        // Basenames only (no path), so the grid's "is this book on device?"
        // check works whether the book sits at the top level or inside an
        // on-device collection folder. Same recursion + filter as `files()`.
        Set(files().map(\.name))
    }

    func files() -> [DeviceFile] {
        let documents = volumeURL.appending(component: "documents")
        let documentsPath = documents.path(percentEncoded: false)
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ]
        guard
            let enumerator = FileManager.default.enumerator(
                at: documents,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        var results: [DeviceFile] = []
        for case let url as URL in enumerator {
            // `.sdr` is the per-book annotations sidecar — skip the folder
            // and everything inside it (highlights, last-read position, etc.
            // — not books). `skipDescendants` only works while we're sitting
            // on the directory entry itself.
            if url.pathExtension.lowercased() == "sdr" {
                enumerator.skipDescendants()
                continue
            }
            guard
                let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true
            else { continue }

            // Only surface things the device scanner indexes. Random filesystem
            // cruft (.notifications, log files Amazon writes) shouldn't appear
            // as deletable books in the UI.
            let ext = url.pathExtension.lowercased()
            guard supportedFormats.contains(ext) else { continue }

            // Path relative to `documents/`. For top-level files this equals
            // the basename; for on-device collection folders it's
            // "<Folder>/<file>".
            let fullPath = url.path(percentEncoded: false)
            let relative: String
            if fullPath.hasPrefix(documentsPath + "/") {
                relative = String(fullPath.dropFirst(documentsPath.count + 1))
            } else {
                relative = url.lastPathComponent
            }

            // Hide Amazon's pre-installed content (My Clippings, guides,
            // dictionaries) so the management UI is focused on user books.
            if isSystemFile(relativePath: relative) { continue }

            results.append(
                DeviceFile(
                    relativePath: relative,
                    size: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate ?? .distantPast
                )
            )
        }
        return results
    }

    /// Pre-installed Kindle content we don't want users deleting accidentally
    /// (or — for dictionaries — content that's recoverable but better managed
    /// via the on-device Settings flow). The `supportedFormats` whitelist
    /// already filters non-book extensions, so this only needs to catch
    /// things that *look* like books but aren't user content.
    ///
    /// Two layers:
    ///  - exact stem matches for well-known Amazon files (`My Clippings`,
    ///    User's Guides, Welcome, etc.)
    ///  - brand-anchored dictionary detection — stem must contain BOTH an
    ///    Amazon dictionary publisher (Oxford, Duden…) AND the word
    ///    "dictionary"/"diccionario"/"…" to avoid hiding user books like
    ///    "The Devil's Dictionary" by Ambrose Bierce.
    nonisolated func isSystemFile(relativePath: String) -> Bool {
        let basename = (relativePath as NSString).lastPathComponent
        let stem = ((basename as NSString).deletingPathExtension).lowercased()

        let amazonStems: Set<String> = [
            "my clippings",
            "kindle user's guide",
            "user's guide",
            "welcome",
            "getting started",
            "quick tour",
        ]
        if amazonStems.contains(stem) { return true }

        // Localized "dictionary" words. These are nouns that are
        // *specifically* used for dictionaries in their languages, so
        // hiding on stem-contains alone is safe — minimal false-positive
        // risk for user books.
        let localizedDictionaryWords = [
            "dicionário", "dictionnaire", "wörterbuch", "diccionario",
        ]
        if localizedDictionaryWords.contains(where: { stem.contains($0) }) {
            return true
        }

        // English "dictionary": require co-occurrence with a known Amazon
        // dictionary publisher so a user's "Devil's Dictionary" stays
        // visible.
        if stem.contains("dictionary") {
            let publishers = ["oxford", "duden", "larousse", "sanseido"]
            if publishers.contains(where: { stem.contains($0) }) {
                return true
            }
        }

        return false
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
            // Re-send semantics: an existing copy on the device is replaced
            // rather than rejected. FAT/exFAT volumes don't expose atomic-
            // replace primitives, so we accept the brief window between
            // removeItem and copyItem — the user is the one initiating the
            // action; the Kindle's scanner doesn't poll mid-write. The
            // matching `.sdr/` annotations sidecar is keyed by filename and
            // stays put, so highlights survive the replace.
            if fm.fileExists(atPath: dest.path(percentEncoded: false)) {
                do {
                    try fm.removeItem(at: dest)
                } catch {
                    throw BookDeviceError.copyFailed(underlying: error)
                }
            }
            do {
                try fm.copyItem(at: source, to: dest)
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

    func removeFile(at relativePath: String) async throws {
        // `appending(path:)` handles "Folder/file.azw3" correctly — the
        // segments resolve into the URL structure.
        let dest =
            volumeURL
            .appending(component: "documents")
            .appending(path: relativePath)
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
