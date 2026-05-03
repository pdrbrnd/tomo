import Foundation
import os

enum LibraryImporterError: LocalizedError {
    case parsingFailed
    case destinationExists

    var errorDescription: String? {
        switch self {
        case .parsingFailed: "Could not read EPUB metadata."
        case .destinationExists: "A book with this title and author is already in the library."
        }
    }
}

actor LibraryImporter {
    private let index: BookIndex
    private let profiles: [LanguageProfile]

    init(index: BookIndex, profiles: [LanguageProfile]) {
        self.index = index
        self.profiles = profiles
    }

    func importBook(from sourceURL: URL, into libraryFolder: URL) async throws -> Book {
        libraryLogger.info("importing \(sourceURL.lastPathComponent, privacy: .public)")

        let metadata: EPUBMetadata
        do {
            metadata = try EPUBMetadata.read(from: sourceURL)
        } catch {
            libraryLogger.error("metadata parse failed: \(error.localizedDescription, privacy: .public)")
            throw LibraryImporterError.parsingFailed
        }

        let bookFolder = bookFolderURL(in: libraryFolder, metadata: metadata)
        let destFile = bookFolder.appending(component: sourceURL.lastPathComponent)

        if FileManager.default.fileExists(atPath: destFile.path(percentEncoded: false)) {
            throw LibraryImporterError.destinationExists
        }

        try FileManager.default.createDirectory(at: bookFolder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: destFile)

        // Past this point, any failure must roll back the partially-created folder.
        do {
            let coverFileName = writeCover(metadata.coverImage, in: bookFolder)

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

            libraryLogger.info("imported: \(book.title, privacy: .public) by \(book.authors.first ?? "Unknown", privacy: .public)")
            classify(at: destFile)
            return book
        } catch {
            do {
                try FileManager.default.trashItem(at: bookFolder, resultingItemURL: nil)
                libraryLogger.warning("rolled back partial import: \(bookFolder.path(percentEncoded: false), privacy: .public)")
            } catch let cleanupError {
                libraryLogger.error("rollback failed for \(bookFolder.path(percentEncoded: false), privacy: .public): \(cleanupError.localizedDescription, privacy: .public)")
            }
            throw error
        }
    }

    private func classify(at fileURL: URL) {
        let text: String
        do {
            text = try EPUBText.extract(from: fileURL)
        } catch {
            classifierLogger.error("text extract failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard !text.isEmpty else {
            classifierLogger.info("empty extracted text — skipping classification")
            return
        }
        guard let baseLang = BaseLanguage.detect(in: text) else {
            classifierLogger.info("could not detect base language")
            return
        }
        let candidates = profiles.filter { $0.baseLanguage == baseLang }
        guard !candidates.isEmpty else {
            classifierLogger.info("no profiles for base language \(baseLang, privacy: .public)")
            return
        }
        if let result = ProfileClassifier.classify(text: text, profiles: candidates) {
            classifierLogger.info("classified: base=\(baseLang, privacy: .public) profile=\(result.profileId, privacy: .public) confidence=\(result.confidence, format: .fixed(precision: 2))")
        } else {
            classifierLogger.info("base=\(baseLang, privacy: .public) but no marker matches")
        }
    }
}

private nonisolated func writeCover(_ cover: EPUBMetadata.CoverImage?, in bookFolder: URL) -> String? {
    guard let cover else { return nil }
    let name = "cover.\(cover.pathExtension)"
    do {
        try cover.data.write(to: bookFolder.appending(component: name), options: .atomic)
        return name
    } catch {
        libraryLogger.error("cover write failed: \(error.localizedDescription, privacy: .public)")
        return nil
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
