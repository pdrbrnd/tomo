import AZW3
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// Writes the cover thumbnail to a connected Kindle's `system/thumbnails/`
/// folder so the home-screen scanner picks up the cover. Without this,
/// sideloaded books on most current Kindle firmwares display a generic
/// placeholder regardless of the EXTH 201 cover record embedded in the
/// AZW3 itself — Amazon's home-screen grid pulls covers from this folder,
/// not from inside the book.
///
/// Filename format mirrors Calibre and Amazon:
/// `thumbnail_<ASIN>_<CDETYPE>_portrait.jpg`. The ASIN must match what the
/// AZW3 writer stamped into EXTH 113 — `AZW3Writer.asin` exposes that
/// value deterministically from the manifest.
///
/// JPEGs are ~500px tall (Calibre's `KINDLE2.THUMBNAIL_HEIGHT`); width
/// follows the cover's aspect ratio. Older Kindle models use smaller
/// targets but all accept 500.
nonisolated enum KindleCoverThumbnail {
    static let thumbnailHeight = 500
    static let thumbnailsSubpath = "system/thumbnails"
    static let cdeType = "EBOK"
    /// Tomo-owned mirror of every cover we ship to `system/thumbnails/`.
    /// On reconnect we copy from here back over anything Amazon's home-screen
    /// scanner has wiped. Sits under `.tomo/` so it's hidden from the user's
    /// view when they browse the device in Finder, and namespaced away from
    /// Calibre's `amazon-cover-bug/` (each tool owns its own cache).
    static let coverCacheSubpath = ".tomo/cover-thumbnails"

    /// Best-effort cover write. No-op when the manifest has no cover.
    /// Throws on filesystem errors — caller handles non-fatally (book is
    /// still usable; just won't show a custom cover on the home screen).
    static func write(manifest: BookManifest, volumeURL: URL) throws {
        guard let cover = manifest.cover else {
            // Surfaces "no cover in book" vs. "write failed" in the logs so
            // future repro sessions can tell why the home-screen tile fell
            // back to a placeholder.
            deliveryLogger.info("kindle thumbnail skipped: manifest has no cover")
            return
        }

        let asin = AZW3Writer(manifest: manifest).asin
        let dir = volumeURL.appending(
            component: thumbnailsSubpath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let filename = "thumbnail_\(asin)_\(cdeType)_portrait.jpg"
        let dest = dir.appending(component: filename)
        let bytes = resizeAsJPEG(cover.bytes, height: thumbnailHeight) ?? cover.bytes
        try bytes.write(to: dest, options: .atomic)
        deliveryLogger.info(
            "kindle thumbnail wrote \(bytes.count) bytes to \(filename, privacy: .public)")

        // Mirror to the Tomo cache so `restoreOverwrittenThumbnails` can put
        // the cover back after Amazon's home-screen scanner wipes it. The
        // cache write is best-effort — failing here only loses the auto-
        // restore behaviour, not the cover the user just sent.
        let cacheDir = volumeURL.appending(
            component: coverCacheSubpath, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: cacheDir, withIntermediateDirectories: true)
            try bytes.write(to: cacheDir.appending(component: filename), options: .atomic)
        } catch {
            deliveryLogger.warning(
                "kindle thumbnail cache write failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Re-copies any cached cover thumbnails over the corresponding files in
    /// `system/thumbnails/` whenever they're missing or differ in size from
    /// the cache copy. Mirrors Calibre's `sync_cover_thumbnails` in
    /// `devices/kindle/driver.py`: the size mismatch catches Amazon's "no
    /// image available" placeholder, which is ~60×40 px JPEG (a few hundred
    /// bytes) and much smaller than the cached 500 px thumbnails. Called from
    /// the device-mount handler so reconnecting the Kindle resurrects any
    /// covers Amazon wiped while the user was online.
    ///
    /// Best-effort: returns the number of restorations performed; never
    /// throws. Caller can ignore the return value — logging covers the
    /// observability need.
    @discardableResult
    static func restoreOverwrittenThumbnails(volumeURL: URL) -> Int {
        let fm = FileManager.default
        let cacheDir = volumeURL.appending(
            component: coverCacheSubpath, directoryHint: .isDirectory)
        let systemDir = volumeURL.appending(
            component: thumbnailsSubpath, directoryHint: .isDirectory)

        var isDir: ObjCBool = false
        guard
            fm.fileExists(atPath: cacheDir.path(percentEncoded: false), isDirectory: &isDir),
            isDir.boolValue,
            fm.fileExists(atPath: systemDir.path(percentEncoded: false), isDirectory: &isDir),
            isDir.boolValue
        else { return 0 }

        let cached: [URL]
        do {
            cached = try fm.contentsOfDirectory(
                at: cacheDir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            deliveryLogger.warning(
                "kindle thumbnail cache scan failed: \(error.localizedDescription, privacy: .public)"
            )
            return 0
        }

        var restored = 0
        for src in cached {
            let name = src.lastPathComponent
            let dest = systemDir.appending(component: name)
            // -1 sentinel for "dest missing" — guarantees mismatch with the
            // ≥0 src size, so a missing system file triggers a restore.
            let destSize = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            let srcSize = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard destSize != srcSize else { continue }
            do {
                let data = try Data(contentsOf: src)
                try data.write(to: dest, options: .atomic)
                restored += 1
            } catch {
                deliveryLogger.warning(
                    "kindle thumbnail restore failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        if restored > 0 {
            deliveryLogger.info(
                "kindle thumbnail restored \(restored) cover(s) overwritten by amazon")
        }
        return restored
    }

    /// Resizes raw image bytes (JPEG, PNG, GIF) to `height` px tall while
    /// preserving aspect ratio, returning JPEG bytes. Returns nil on
    /// unrecognized input — caller falls back to the original.
    private static func resizeAsJPEG(_ bytes: Data, height: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let aspect = CGFloat(cgImage.width) / CGFloat(cgImage.height)
        let targetWidth = max(1, Int(CGFloat(height) * aspect))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: targetWidth,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: height))
        guard let resized = context.makeImage() else { return nil }

        let outData = NSMutableData()
        guard
            let dest = CGImageDestinationCreateWithData(
                outData as CFMutableData,
                UTType.jpeg.identifier as CFString,
                1, nil
            )
        else { return nil }
        CGImageDestinationAddImage(
            dest,
            resized,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        )
        guard CGImageDestinationFinalize(dest) else { return nil }
        return outData as Data
    }
}
