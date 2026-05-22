import AppKit
import Foundation

/// Rasterises vector cover images (SVG) into JPEG. Kindle's KF8 reader
/// nominally supports SVG records but real-world devices render them
/// inconsistently, so we always emit JPEG.
nonisolated enum CoverRasterizer {
    private static let kindleCoverSize = CGSize(width: 1200, height: 1600)
    private static let jpegQuality: Double = 0.85

    /// Re-encodes arbitrary `NSImage`-decodable bytes (HEIC, TIFF, WebP,
    /// BMP, etc.) to JPEG at the source image's natural dimensions.
    /// Used by the cover-override path so user-picked images in formats
    /// the AZW3 writer doesn't support still reach the Kindle. Returns
    /// nil if the bytes can't be decoded.
    static func reencodeToJPEG(_ data: Data) -> Data? {
        guard let image = NSImage(data: data),
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: NSNumber(value: jpegQuality)]
        )
    }

    /// Renders SVG bytes to JPEG at a Kindle-friendly resolution.
    /// Returns nil if the input can't be decoded as an image.
    static func rasterizeSVG(
        _ data: Data,
        pixelSize: CGSize = kindleCoverSize
    ) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(pixelSize.width),
                pixelsHigh: Int(pixelSize.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else { return nil }
        bitmap.size = pixelSize
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: CGRect(origin: .zero, size: pixelSize))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: NSNumber(value: jpegQuality)])
    }
}
