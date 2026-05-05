import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import os

/// Metadata extracted from a PDF for the import flow. Same shape as
/// `EPUBMetadata` so the importer can dispatch on file extension and
/// hand a uniform value off to its folder-laying / cover-writing helpers.
struct PDFMetadata: Sendable {
    let title: String
    let authors: [String]
    let language: String?
    let year: Int?
    let coverImage: CoverImage?

    struct CoverImage: Sendable {
        let data: Data
        let pathExtension: String
    }
}

extension PDFMetadata {
    /// Reads `/Info` (title, author, creation date) from the PDF and renders
    /// page 1 as a JPEG cover. Falls back to the filename when `/Title` is
    /// missing or junk (very common — Word "Save As PDF" leaves "Microsoft
    /// Word - foo.docx" in there). Locale stays `nil`; PDFs don't carry a
    /// reliable language tag.
    nonisolated static func read(from url: URL) throws -> PDFMetadata {
        guard let pdf = PDFDocument(url: url) else {
            throw PDFMetadataError.cannotOpen
        }

        let info = pdf.documentAttributes ?? [:]
        let rawTitle =
            (info[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title =
            isJunkPDFTitle(rawTitle)
            ? url.deletingPathExtension().lastPathComponent
            : rawTitle

        let authors: [String]
        if let raw = info[PDFDocumentAttribute.authorAttribute] as? String,
            !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            // PDF /Author is a single string; split on the common author-list
            // separators users put there. Empty pieces dropped.
            authors =
                raw
                .components(separatedBy: CharacterSet(charactersIn: ";,&"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            authors = []
        }

        let year = (info[PDFDocumentAttribute.creationDateAttribute] as? Date).map {
            Calendar(identifier: .gregorian).component(.year, from: $0)
        }

        return PDFMetadata(
            title: title,
            authors: authors,
            language: nil,
            year: year,
            coverImage: renderFirstPageAsJPEG(pdf)
        )
    }
}

/// Recognises common garbage `/Title` values and forces a filename fallback.
/// Word, LaTeX, and various export pipelines all leave debris there.
private nonisolated func isJunkPDFTitle(_ candidate: String) -> Bool {
    if candidate.isEmpty { return true }
    let lower = candidate.lowercased()
    if lower.hasPrefix("microsoft word -") { return true }
    if lower.hasPrefix("untitled") { return true }
    if lower.hasSuffix(".pdf") || lower.hasSuffix(".docx") || lower.hasSuffix(".doc") {
        return true
    }
    return false
}

/// Renders the first page to a 600px-long-side JPEG with a white background
/// (PDF pages are transparent by default).
private nonisolated func renderFirstPageAsJPEG(_ pdf: PDFDocument) -> PDFMetadata.CoverImage? {
    guard let page = pdf.page(at: 0) else { return nil }
    let pageRect = page.bounds(for: .mediaBox)
    guard pageRect.width > 0, pageRect.height > 0 else { return nil }

    let longSide = max(pageRect.width, pageRect.height)
    let scale = 600.0 / longSide
    let width = max(1, Int(pageRect.width * scale))
    let height = max(1, Int(pageRect.height * scale))

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    else { return nil }

    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: context)

    guard let cgImage = context.makeImage() else { return nil }

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
        cgImage,
        [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
    )
    guard CGImageDestinationFinalize(dest) else { return nil }

    return PDFMetadata.CoverImage(data: outData as Data, pathExtension: "jpg")
}

enum PDFMetadataError: LocalizedError {
    case cannotOpen

    var errorDescription: String? {
        switch self {
        case .cannotOpen: "Could not open the PDF (file may be corrupted or encrypted)."
        }
    }
}
