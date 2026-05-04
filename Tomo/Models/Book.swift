import Foundation

nonisolated struct Book: Sendable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var authors: [String]
    var year: Int?
    var locale: String                 // BCP 47: "pt-PT", "pt", "en-US", "und"
    var coverPath: String?             // relative to the book's folder
    var dateAdded: Date
    var fileURL: URL                   // absolute path to primary file
    var origin: BookOrigin
    /// Collections this book belongs to. Populated by the index from the
    /// `book_collections` join table; not stored on the row directly. The
    /// sidecar mirrors the *names* of these collections for resilience —
    /// see `MetadataSidecar`.
    var collectionIDs: Set<UUID> = []

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

nonisolated enum BookOrigin: Codable, Sendable, Equatable, Hashable {
    case manualImport
    case source(id: String, ref: String?)
}
