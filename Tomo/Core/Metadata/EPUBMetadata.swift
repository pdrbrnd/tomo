import Foundation
import os

struct EPUBMetadata: Sendable {
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

extension EPUBMetadata {
    nonisolated static func read(from url: URL) throws -> EPUBMetadata {
        let epub = try EPUBArchive.open(url)
        guard let title = epub.opf.title else {
            throw EPUBArchiveError.missingTitle
        }
        return EPUBMetadata(
            title: title,
            authors: epub.opf.authors,
            language: epub.opf.language,
            year: epub.opf.date.flatMap(yearFromEPUBDate),
            coverImage: readCover(from: epub)
        )
    }
}

private nonisolated func yearFromEPUBDate(_ raw: String) -> Int? {
    if let date = parseEPUBDate(raw) {
        return Calendar(identifier: .gregorian).component(.year, from: date)
    }
    return Int(raw.prefix(4))
}

private nonisolated func readCover(from epub: EPUBArchive) -> EPUBMetadata.CoverImage? {
    guard let item = epub.opf.coverItem else { return nil }
    guard let data = epub.data(forResourceHref: item.href) else {
        metadataLogger.error("cover entry not found: \(item.href, privacy: .public)")
        return nil
    }
    return EPUBMetadata.CoverImage(
        data: data,
        pathExtension: (item.href as NSString).pathExtension
    )
}
