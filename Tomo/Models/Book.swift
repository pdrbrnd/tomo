import Foundation

nonisolated struct Book: Sendable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var authors: [String]
    var series: [BookSeries] = []
    var year: Int?
    var locale: String  // BCP 47: "pt-PT", "pt", "en-US", "und"
    var coverPath: String?  // relative to the book's folder
    var dateAdded: Date
    var fileURL: URL  // absolute path to primary file
    /// Collections this book belongs to. Populated by the index from the
    /// `book_collections` join table; not stored on the row directly. The
    /// sidecar mirrors the *names* of these collections for resilience —
    /// see `MetadataSidecar`.
    var collectionIDs: Set<UUID> = []
    /// Which metadata this book has been filled with from its file. Books
    /// imported by an older version sit below `currentMetadataVersion` until
    /// `MetadataMigration` reads the fields added since. Persisted as the
    /// sidecar's `version`.
    var metadataVersion: Int = Book.currentMetadataVersion

    /// Bump when import starts reading a new field from the file, and add
    /// the matching step to `MetadataMigration`.
    ///   - 1: title, authors, year, language, cover
    ///   - 2: series
    static let currentMetadataVersion = 2

    var coverURL: URL? {
        guard let coverPath else { return nil }
        return fileURL.deletingLastPathComponent().appending(component: coverPath)
    }

    /// Human-readable name for the locale, derived from the BCP 47 tag via
    /// Apple's `Locale` API. Localized to the user's UI language. "und"
    /// resolves to a system-provided "Unknown language" string.
    var localeDisplayName: String {
        Locale.current.localizedString(forIdentifier: locale) ?? locale
    }
}
