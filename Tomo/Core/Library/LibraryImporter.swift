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
            let coverFileName = writeCover(metadata.coverImage, for: metadata.title, in: bookFolder)
            let locale = resolveLocale(declared: metadata.language, file: destFile)

            let book = Book(
                id: UUID(),
                title: metadata.title,
                authors: metadata.authors,
                year: metadata.year,
                locale: locale,
                coverPath: coverFileName,
                dateAdded: .now,
                fileURL: destFile,
                origin: .manualImport
            )

            // Fresh import: no collections yet. Membership is added later
            // from the inspector / drag-to-sidebar.
            try MetadataSidecar.write(book, collectionNames: [], to: bookFolder)
            try await index.add(book)

            libraryLogger.info(
                "imported: \(book.title, privacy: .public) by \(book.authors.first ?? "Unknown", privacy: .public)")
            return book
        } catch {
            do {
                try FileManager.default.trashItem(at: bookFolder, resultingItemURL: nil)
                libraryLogger.warning(
                    "rolled back partial import: \(bookFolder.path(percentEncoded: false), privacy: .public)")
            } catch let cleanupError {
                libraryLogger.error(
                    "rollback failed for \(bookFolder.path(percentEncoded: false), privacy: .public): \(cleanupError.localizedDescription, privacy: .public)"
                )
            }
            throw error
        }
    }

    /// Decide the book's locale: trust the EPUB-declared full locale when it
    /// matches a known profile, otherwise classify (only applied above the
    /// confidence threshold — uncertain results would be coin flips), otherwise
    /// fall back to the EPUB's raw declaration or "und". The classifier still
    /// logs its confidence as a dev-time signal.
    private func resolveLocale(declared: String?, file: URL) -> String {
        if let declared,
            let direct = profiles.first(where: { $0.id.caseInsensitiveCompare(declared) == .orderedSame })
        {
            classifierLogger.info("trusting EPUB-declared locale: \(declared, privacy: .public)")
            return direct.id
        }
        if let result = Classifier.classifyEPUB(at: file, profiles: profiles),
            result.confidence >= Self.classificationThreshold
        {
            return result.profileId
        }
        return declared ?? "und"
    }

    /// Below this, the classifier is essentially guessing between variants —
    /// fall back to the base declaration rather than commit a coin-flip variant.
    private static let classificationThreshold = 0.6
}

private nonisolated func writeCover(
    _ cover: EPUBMetadata.CoverImage?,
    for title: String,
    in bookFolder: URL
) -> String? {
    guard let cover else { return nil }
    let name = "cover.\(cover.pathExtension)"
    do {
        try cover.data.write(to: bookFolder.appending(component: name), options: .atomic)
        return name
    } catch {
        // Non-fatal: import proceeds with no cover, user can fetch one later.
        libraryLogger.error(
            "cover write failed for \(title, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        return nil
    }
}

private nonisolated func bookFolderURL(in libraryFolder: URL, metadata: EPUBMetadata) -> URL {
    let author = sanitize(metadata.authors.first ?? "Unknown")
    let titlePart = sanitize(metadata.title)
    let folderName = metadata.year.map { "\(titlePart) (\($0))" } ?? titlePart
    return
        libraryFolder
        .appending(component: author)
        .appending(component: folderName)
}

private nonisolated func sanitize(_ raw: String) -> String {
    let invalid = CharacterSet(charactersIn: "/:\\?*\"<>|")
    let cleaned = raw.components(separatedBy: invalid).joined(separator: "-")
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
}
