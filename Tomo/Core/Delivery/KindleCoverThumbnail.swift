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
