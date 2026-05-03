import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.pdrbrnd.tinta", category: "library")

enum LibraryImporterError: Error {
    case parsingFailed
    case destinationExists
}

actor LibraryImporter {
    private let index: BookIndex

    init(index: BookIndex) {
        self.index = index
    }

    func importBook(from sourceURL: URL, into libraryFolder: URL) async throws -> Book {
        logger.info("importing \(sourceURL.lastPathComponent, privacy: .public)")

        let metadata: EPUBMetadata
        do {
            metadata = try EPUBMetadata.read(from: sourceURL)
        } catch {
            logger.error("metadata parse failed: \(error.localizedDescription, privacy: .public)")
            throw LibraryImporterError.parsingFailed
        }

        let bookFolder = bookFolderURL(in: libraryFolder, metadata: metadata)
        let destFile = bookFolder.appending(component: sourceURL.lastPathComponent)

        if FileManager.default.fileExists(atPath: destFile.path(percentEncoded: false)) {
            throw LibraryImporterError.destinationExists
        }

        try FileManager.default.createDirectory(at: bookFolder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: destFile)

        let coverFileName: String? = {
            guard let cover = metadata.coverImage else { return nil }
            let name = "cover.\(cover.pathExtension)"
            do {
                try cover.data.write(to: bookFolder.appending(component: name), options: .atomic)
                return name
            } catch {
                logger.error("cover write failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }()

        let book = Book(
            id: UUID(),
            title: metadata.title,
            authors: metadata.authors,
            year: metadata.year,
            languageCode: metadata.language ?? "und",
            coverPath: coverFileName,
            dateAdded: .now,
            fileURL: destFile,
            origin: .manualImport
        )

        try MetadataSidecar.write(book, to: bookFolder)
        try await index.add(book)

        logger.info("imported: \(book.title, privacy: .public) by \(book.authors.first ?? "Unknown", privacy: .public)")
        return book
    }
}

private nonisolated func bookFolderURL(in libraryFolder: URL, metadata: EPUBMetadata) -> URL {
    let author = sanitize(metadata.authors.first ?? "Unknown")
    let titlePart = sanitize(metadata.title)
    let folderName = metadata.year.map { "\(titlePart) (\($0))" } ?? titlePart
    return libraryFolder
        .appending(component: author)
        .appending(component: folderName)
}

private nonisolated func sanitize(_ raw: String) -> String {
    let invalid = CharacterSet(charactersIn: "/:\\?*\"<>|")
    let cleaned = raw.components(separatedBy: invalid).joined(separator: "-")
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
}
