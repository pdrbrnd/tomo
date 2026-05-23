import Foundation
import os

enum LibraryImporterError: LocalizedError {
    case unsupportedFormat(String)
    case parsingFailed
    case destinationExists

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Tomo doesn't import .\(ext) files yet."
        case .parsingFailed:
            return "Could not read the file's metadata."
        case .destinationExists:
            return "A book with this title and author is already in the library."
        }
    }
}

actor LibraryImporter {
    private let index: BookIndex

    init(index: BookIndex) {
        self.index = index
    }

    /// File extensions the importer knows how to read. Lowercase, no leading
    /// dot. Surfaced to UI (drop overlay, error messages) so the accepted
    /// list stays in one place.
    static let acceptedExtensions: Set<String> = ["epub", "pdf"]

    static func canImport(_ url: URL) -> Bool {
        acceptedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Expands a drop selection into a flat list of file URLs ready for the
    /// `canImport` partition. Directories are walked recursively, yielding
    /// only files whose extension is in `acceptedExtensions` — junk files
    /// inside a dropped folder are silently skipped (the user's intent is
    /// "import what you can", not "warn me about every non-book file").
    /// Regular files pass through unchanged; the caller still runs them
    /// through `canImport` so top-level unsupported drops get the usual
    /// error toast.
    static func expand(_ urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            let isDirectory =
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if !isDirectory { return [url] }
            guard
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            else { return [] }
            return enumerator.compactMap { item in
                guard let fileURL = item as? URL else { return nil }
                let isFile =
                    (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?
                    .isRegularFile ?? false
                guard isFile,
                    acceptedExtensions.contains(fileURL.pathExtension.lowercased())
                else { return nil }
                return fileURL
            }
        }
    }

    /// Pretty list for UI surfaces ("EPUB and PDF"). Sorted, uppercased,
    /// joined with " and " when there are two — Oxford comma otherwise.
    static var acceptedExtensionsDisplay: String {
        let sorted = acceptedExtensions.sorted().map { $0.uppercased() }
        switch sorted.count {
        case 0: return ""
        case 1: return sorted[0]
        case 2: return "\(sorted[0]) and \(sorted[1])"
        default:
            let head = sorted.dropLast().joined(separator: ", ")
            return "\(head), and \(sorted.last!)"
        }
    }

    func importBook(
        from sourceURL: URL,
        into libraryFolder: URL,
        profiles: [LanguageProfile],
        origin: BookOrigin
    ) async throws -> Book {
        libraryLogger.info("importing \(sourceURL.lastPathComponent, privacy: .public)")

        let metadata: ImportedFileMetadata
        do {
            metadata = try Self.readMetadata(from: sourceURL)
        } catch let err as LibraryImporterError {
            throw err
        } catch {
            libraryLogger.error("metadata parse failed: \(error.localizedDescription, privacy: .public)")
            throw LibraryImporterError.parsingFailed
        }

        let bookFolder = bookFolderURL(in: libraryFolder, metadata: metadata)
        let ext = sourceURL.pathExtension.lowercased()
        let bookID = UUID()
        let filename = bookFileSlug(
            title: metadata.title,
            author: metadata.authors.first,
            year: metadata.year,
            ext: ext,
            id: bookID
        )
        let destFile = bookFolder.appending(component: filename)

        if FileManager.default.fileExists(atPath: destFile.path(percentEncoded: false)) {
            throw LibraryImporterError.destinationExists
        }

        try FileManager.default.createDirectory(at: bookFolder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: destFile)

        // Past this point, any failure must roll back the partially-created folder.
        do {
            let coverFileName = writeCover(metadata.coverImage, for: metadata.title, in: bookFolder)
            let locale = Self.resolveLocale(declared: metadata.language, file: destFile, profiles: profiles)

            let book = Book(
                id: bookID,
                title: metadata.title,
                authors: metadata.authors,
                year: metadata.year,
                locale: locale,
                coverPath: coverFileName,
                dateAdded: .now,
                fileURL: destFile,
                origin: origin
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

    /// Per-format dispatch. Each branch returns the same uniform metadata
    /// shape so the rest of the import flow doesn't care which file type
    /// it came from. Classifier only runs for EPUBs (it inspects HTML
    /// content, which the AZW3/MOBI/PDF readers don't surface).
    private static func readMetadata(from url: URL) throws -> ImportedFileMetadata {
        switch url.pathExtension.lowercased() {
        case "epub":
            let m = try EPUBMetadata.read(from: url)
            return ImportedFileMetadata(
                title: m.title,
                authors: m.authors,
                language: m.language,
                year: m.year,
                coverImage: m.coverImage.map {
                    ImportedFileMetadata.CoverImage(data: $0.data, pathExtension: $0.pathExtension)
                }
            )
        case "pdf":
            let m = try PDFMetadata.read(from: url)
            return ImportedFileMetadata(
                title: m.title,
                authors: m.authors,
                language: m.language,
                year: m.year,
                coverImage: m.coverImage.map {
                    ImportedFileMetadata.CoverImage(data: $0.data, pathExtension: $0.pathExtension)
                }
            )
        default:
            throw LibraryImporterError.unsupportedFormat(url.pathExtension.lowercased())
        }
    }

    /// Decide the book's locale: trust the declared full locale when it
    /// matches a known profile, otherwise classify (only applied above the
    /// confidence threshold — uncertain results would be coin flips), otherwise
    /// fall back to the declaration or "und". Classifier only inspects EPUB
    /// content; for non-EPUBs the EPUB path returns nil and we land at "und".
    /// `profiles` is the user-enabled set — disabled profiles never appear in
    /// the declared-match shortcut nor in classifier output.
    private static func resolveLocale(
        declared: String?, file: URL, profiles: [LanguageProfile]
    ) -> String {
        if let declared,
            let direct = profiles.first(where: { $0.id.caseInsensitiveCompare(declared) == .orderedSame })
        {
            classifierLogger.info("trusting declared locale: \(declared, privacy: .public)")
            return direct.id
        }
        if file.pathExtension.lowercased() == "epub",
            let result = Classifier.classifyEPUB(at: file, profiles: profiles),
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

/// Common metadata shape the importer consumes, populated by per-format
/// readers (`EPUBMetadata`, `PDFMetadata`). Internal to the importer —
/// downstream code uses `Book` after persistence.
struct ImportedFileMetadata: Sendable {
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

private nonisolated func writeCover(
    _ cover: ImportedFileMetadata.CoverImage?,
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

private nonisolated func bookFolderURL(in libraryFolder: URL, metadata: ImportedFileMetadata) -> URL {
    LibraryLayout.bookFolderURL(
        in: libraryFolder,
        title: metadata.title,
        firstAuthor: metadata.authors.first,
        year: metadata.year
    )
}
