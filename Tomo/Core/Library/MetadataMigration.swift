import Foundation

/// Brings books imported by older versions up to date with metadata that
/// newer versions read from the file on import (series, so far).
///
/// Each step only fills a field introduced at its version, and only when
/// it's empty, so it never overrides a user's choice: a sidecar below that
/// version was written before the user could set the field.
nonisolated enum MetadataMigration {

    /// What reading a book's file produced.
    enum Source: Sendable {
        /// iCloud placeholder. Leave the book as is and retry on a later
        /// sync rather than triggering a download.
        case evicted
        /// EPUB metadata to migrate from.
        case opf(ParsedOPF)
        /// Nothing to read (PDF, or an EPUB that won't parse). The version
        /// still gets bumped so the book isn't retried forever.
        case none
    }

    /// Steps in order; each brings a book *to* its version. Add one whenever
    /// `Book.currentMetadataVersion` is bumped.
    private static let steps: [(version: Int, apply: @Sendable (inout Book, ParsedOPF) -> Void)] = [
        (2, { book, opf in if book.series.isEmpty { book.series = opf.series } }),
    ]

    static func needsMigration(_ book: Book) -> Bool {
        book.metadataVersion < Book.currentMetadataVersion
    }

    /// Reads the file's metadata. Blocking I/O — call off the main actor.
    static func readSource(for book: Book) -> Source {
        if CoordinatedRead.needsDownload(book.fileURL) { return .evicted }
        guard book.fileURL.pathExtension.lowercased() == "epub",
            let epub = try? EPUBArchive.open(book.fileURL)
        else { return .none }
        return .opf(epub.opf)
    }

    /// `book` with every step above its version applied, at the current
    /// version. Pass the book as it is *now* (not when `source` was read),
    /// so edits made in the meantime survive.
    static func migrated(_ book: Book, from source: Source) -> Book {
        var updated = book
        if case .opf(let opf) = source {
            for step in steps where step.version > book.metadataVersion {
                step.apply(&updated, opf)
            }
        }
        updated.metadataVersion = Book.currentMetadataVersion
        return updated
    }
}
