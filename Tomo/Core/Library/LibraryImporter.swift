import Foundation
import os

enum LibraryImporterError: LocalizedError {
    case unsupportedFormat(String)
    case parsingFailed
    case destinationExists
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "Tomo doesn't import .\(ext) files yet."
        case .parsingFailed:
            return "Could not read the file's metadata."
        case .destinationExists:
            return "A book with this title and author is already in the library."
        case .importFailed(let message):
            return message
        }
    }
}

/// The existing book a `possibleDuplicate` matched, used to explain the match
/// in the progress UI ("Matches 'Dune' by Herbert…").
struct ImportMatch: Sendable {
    let title: String
    let author: String?
}

/// Result of preparing one file for import. `imported` means the file is copied
/// into the library and its `metadata.json` sidecar is written, but the book is
/// *not* yet in the index — batch import collects these and does one bulk
/// `index.addBooks`. The two duplicate flavours are deliberately distinct:
///
/// - `alreadyInLibrary`: the file's exact on-disk identity (`Author/Title
///   (Year)/`) already exists. Terminal — we never merge, so there's nothing to
///   override.
/// - `possibleDuplicate`: matches an existing book by title+author but would
///   land at a *different* path (different year, or the existing one has none).
///   Probably the same work with different metadata; importable on demand.
///
/// All non-imported cases carry the source URL so the UI can offer the right
/// action (import-as-separate / retry / reveal).
enum ImportOutcome: Sendable {
    case imported(Book)
    case alreadyInLibrary(URL)
    case possibleDuplicate(URL, matched: ImportMatch)
    case failed(URL, String)
}

/// Serializes the tiny check-and-claim of duplicate fingerprints so concurrent
/// `prepareImport` calls agree on within-batch duplicates (and against the
/// library snapshot it's seeded with). `claim` returns nil when the fingerprint
/// is newly taken (and records the ref), or the already-recorded match when it
/// was present (i.e. a duplicate).
actor FingerprintClaims {
    private var seen: [String: ImportMatch]

    init(_ initial: [String: ImportMatch]) {
        seen = initial
    }

    func claim(_ fingerprint: String, ref: ImportMatch) -> ImportMatch? {
        if let existing = seen[fingerprint] { return existing }
        seen[fingerprint] = ref
        return nil
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

    /// Single-file import: prepare the file on disk, then index it. Used by the
    /// one-off paths (reader "add to library", plugin download). Batch import
    /// uses `prepareImport` directly and indexes in bulk. Throws so existing
    /// callers keep their toast-on-failure behaviour.
    func importBook(
        from sourceURL: URL,
        into libraryFolder: URL,
        profiles: [LanguageProfile]
    ) async throws -> Book {
        let outcome = await Self.prepareImport(
            from: sourceURL,
            into: libraryFolder,
            profiles: profiles,
            claims: nil,
            allowDuplicate: true
        )
        switch outcome {
        case .imported(let book):
            try await index.add(book)
            libraryLogger.info(
                "imported: \(book.title, privacy: .public) by \(book.authors.first ?? "Unknown", privacy: .public)")
            return book
        case .alreadyInLibrary, .possibleDuplicate:
            // Single-file paths pass claims == nil, so possibleDuplicate can't
            // occur; alreadyInLibrary is an exact on-disk collision. Surface
            // both as the existing "already in library" error.
            throw LibraryImporterError.destinationExists
        case .failed(_, let message):
            throw LibraryImporterError.importFailed(message)
        }
    }

    /// Prepares one file for import without touching the index: reads metadata,
    /// dedup-checks (when `claims` is provided), copies the file in, writes the
    /// cover and the `metadata.json` sidecar. The returned `imported` book is on
    /// disk but not yet indexed — the caller indexes it (`index.add`) or batches
    /// it (`index.addBooks`). Never throws: every failure is a `.failed` outcome
    /// so one bad file can't abort a batch.
    ///
    /// `nonisolated static` on purpose — it touches no actor state, so a batch
    /// can run many of these concurrently off the actor. Duplicate detection is
    /// serialized through `claims` (seed it with the library's fingerprints);
    /// pass `nil` to skip dedup entirely (single-file / import-anyway paths).
    nonisolated static func prepareImport(
        from sourceURL: URL,
        into libraryFolder: URL,
        profiles: [LanguageProfile],
        claims: FingerprintClaims?,
        allowDuplicate: Bool
    ) async -> ImportOutcome {
        libraryLogger.info("importing \(sourceURL.lastPathComponent, privacy: .public)")

        let metadata: ImportedFileMetadata
        do {
            metadata = try readMetadata(from: sourceURL)
        } catch let err as LibraryImporterError {
            return .failed(sourceURL, err.errorDescription ?? "Couldn't import this file.")
        } catch {
            libraryLogger.error("metadata parse failed: \(error.localizedDescription, privacy: .public)")
            return .failed(
                sourceURL,
                LibraryImporterError.parsingFailed.errorDescription
                    ?? "Could not read the file's metadata.")
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

        // Exact on-disk identity already present — terminal. We never merge, so
        // even "import anyway" can't apply here.
        if FileManager.default.fileExists(atPath: destFile.path(percentEncoded: false)) {
            return .alreadyInLibrary(sourceURL)
        }

        // Fingerprint match at a *different* path (different year, or the
        // existing one has none) — probably the same work with different
        // metadata. Skipped by default; the user can import it as a separate
        // book. `allowDuplicate` (import-anyway / single-file paths) skips this.
        if !allowDuplicate, let claims {
            let fingerprint = bookFingerprint(
                title: metadata.title, firstAuthor: metadata.authors.first)
            let ref = ImportMatch(title: metadata.title, author: metadata.authors.first)
            if let matched = await claims.claim(fingerprint, ref: ref) {
                return .possibleDuplicate(sourceURL, matched: matched)
            }
        }

        do {
            try FileManager.default.createDirectory(at: bookFolder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: destFile)
        } catch {
            libraryLogger.error("copy failed: \(error.localizedDescription, privacy: .public)")
            return .failed(sourceURL, "Couldn't copy the file into the library.")
        }

        // Past this point, any failure must roll back the partially-created folder.
        let coverFileName = writeCover(metadata.coverImage, for: metadata.title, in: bookFolder)
        let locale = resolveLocale(declared: metadata.language, file: destFile, profiles: profiles)
        let book = Book(
            id: bookID,
            title: metadata.title,
            authors: metadata.authors,
            year: metadata.year,
            locale: locale,
            coverPath: coverFileName,
            dateAdded: .now,
            fileURL: destFile
        )

        do {
            // Fresh import: no collections yet. Membership is added later
            // from the inspector / drag-to-sidebar.
            try MetadataSidecar.write(book, collectionNames: [], to: bookFolder)
            return .imported(book)
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
            return .failed(sourceURL, "Couldn't write the book's metadata.")
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
