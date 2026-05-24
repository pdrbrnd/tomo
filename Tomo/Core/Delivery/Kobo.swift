import Foundation
import os

/// USB-mass-storage Kobo driver. Identifies a Kobo volume by the presence of
/// `.kobo/` at the volume root — the directory containing `KoboReader.sqlite`
/// and device config, present on every Kobo model from Touch onwards. Books
/// drop at the volume root; Kobo's library scanner walks the whole device on
/// disconnect.
///
/// Simpler than `Kindle` because Kobo's scanner natively indexes EPUB and PDF
/// — which is also everything `LibraryImporter` ingests — so there is no
/// conversion path. Cover artwork is extracted from EPUB metadata by the
/// device itself, so there's no thumbnail-folder workaround either.
nonisolated struct Kobo: BookDevice {
    let volumeURL: URL

    var id: String { volumeURL.path(percentEncoded: false) }
    var displayName: String { "Kobo" }

    /// Init returns nil if the volume doesn't look like a Kobo.
    init?(volumeURL: URL) {
        let fm = FileManager.default
        let kobo = volumeURL.appending(component: ".kobo")
        var isDir: ObjCBool = false
        let koboOK =
            fm.fileExists(atPath: kobo.path(percentEncoded: false), isDirectory: &isDir)
            && isDir.boolValue
        guard koboOK else { return nil }

        self.volumeURL = volumeURL
    }

    /// EPUB and PDF — what Kobo's scanner indexes from sideloads and also
    /// what `LibraryImporter` accepts today. Other Kobo-native formats
    /// (KEPUB, MOBI, CBZ/CBR, FB2, TXT, RTF) are deliberately omitted: a
    /// book can only end up in this whitelist if Tomo can import it in the
    /// first place, so widening here would be cosmetic.
    var supportedFormats: Set<String> {
        ["epub", "pdf"]
    }

    func filenames() -> Set<String> {
        Set(files().map(\.name))
    }

    func files() -> [DeviceFile] {
        let root = volumeURL
        let rootPath = root.path(percentEncoded: false)
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
        ]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        var results: [DeviceFile] = []
        for case let url as URL in enumerator {
            // Visible folders other Kobo tools (Adobe Digital Editions, SD-card
            // add-ons) drop content into. Anything in them isn't user content
            // from Tomo's POV. Dot-prefixed system folders (.kobo,
            // .adobe-digital-editions, .kobo-images) are already excluded via
            // `.skipsHiddenFiles`.
            let name = url.lastPathComponent
            if name == "Digital Editions" || name == "koboExtStorage" {
                enumerator.skipDescendants()
                continue
            }
            guard
                let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true
            else { continue }

            let ext = url.pathExtension.lowercased()
            guard supportedFormats.contains(ext) else { continue }

            // Path relative to the volume root. Top-level files: basename only.
            let fullPath = url.path(percentEncoded: false)
            let relative: String
            if fullPath.hasPrefix(rootPath + "/") {
                relative = String(fullPath.dropFirst(rootPath.count + 1))
            } else {
                relative = url.lastPathComponent
            }

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

    func copy(_ book: Book) async throws {
        let dest = volumeURL.appending(component: deviceFilename(for: book))
        try await performCopy(from: book.fileURL, to: dest)
    }

    private func performCopy(from source: URL, to dest: URL) async throws {
        try await Task.detached {
            let fm = FileManager.default
            // Re-send semantics: an existing copy on the device is replaced
            // rather than rejected. Same trade-off as Kindle — FAT/exFAT
            // doesn't expose atomic-replace primitives.
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

    func removeFile(at relativePath: String) async throws {
        let dest = volumeURL.appending(path: relativePath)
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
}
