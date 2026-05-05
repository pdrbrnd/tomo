import Foundation

/// Result of reading a sidecar — the book metadata plus its collection
/// memberships *by name*. Names not IDs because the index is disposable
/// but names are the stable identity users see and edit. On rebuild,
/// names get resolved (or get-or-created) into actual `Collection` rows.
nonisolated struct LoadedSidecar: Sendable {
    let book: Book
    let collectionNames: [String]
}

nonisolated enum MetadataSidecar {
    static let filename = "metadata.json"

    static func write(_ book: Book, collectionNames: [String], to bookFolder: URL) throws {
        let url = bookFolder.appending(component: filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(SidecarPayload(book: book, collectionNames: collectionNames))
        try data.write(to: url, options: .atomic)
    }

    static func read(from bookFolder: URL) throws -> LoadedSidecar {
        let url = bookFolder.appending(component: filename)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(SidecarPayload.self, from: data)
        return LoadedSidecar(
            book: payload.book(in: bookFolder),
            collectionNames: payload.collections
        )
    }
}

private nonisolated struct SidecarPayload: Codable {
    /// Schema version. Always emitted on write. On read, defaults to 1 when
    /// absent (covers all sidecars written before this field existed). Switch
    /// on this when introducing breaking changes — bump and add migration.
    var version: Int
    var id: UUID
    var title: String
    var authors: [String]
    var year: Int?
    var locale: String
    var coverPath: String?
    var dateAdded: Date
    var fileName: String
    var origin: BookOrigin
    var collections: [String]

    static let currentVersion = 1

    init(book: Book, collectionNames: [String]) {
        self.version = Self.currentVersion
        self.id = book.id
        self.title = book.title
        self.authors = book.authors
        self.year = book.year
        self.locale = book.locale
        self.coverPath = book.coverPath
        self.dateAdded = book.dateAdded
        self.fileName = book.fileURL.lastPathComponent
        self.origin = book.origin
        self.collections = collectionNames
    }

    func book(in folder: URL) -> Book {
        Book(
            id: id,
            title: title,
            authors: authors,
            year: year,
            locale: locale,
            coverPath: coverPath,
            dateAdded: dateAdded,
            fileURL: folder.appending(component: fileName),
            origin: origin
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, title, authors, year, locale, coverPath, dateAdded, fileName, origin,
            collections
        // Legacy keys (sidecars written before the unified-locale refactor):
        case languageCode, languageProfileId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        // Old sidecars (pre-2026-05) didn't persist the book id. Mint one
        // for them — it'll be stable from this read forward because the
        // re-write will include it. Identity is only "lost" for the first
        // post-upgrade rebuild.
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.title = try c.decode(String.self, forKey: .title)
        self.authors = try c.decode([String].self, forKey: .authors)
        self.year = try c.decodeIfPresent(Int.self, forKey: .year)
        self.coverPath = try c.decodeIfPresent(String.self, forKey: .coverPath)
        self.dateAdded = try c.decode(Date.self, forKey: .dateAdded)
        self.fileName = try c.decode(String.self, forKey: .fileName)
        self.origin = try c.decode(BookOrigin.self, forKey: .origin)
        self.collections = try c.decodeIfPresent([String].self, forKey: .collections) ?? []

        if let new = try c.decodeIfPresent(String.self, forKey: .locale) {
            self.locale = new
        } else {
            // Legacy: prefer profile id, fall back to base code, then "und"
            let profileId = try c.decodeIfPresent(String.self, forKey: .languageProfileId)
            let baseCode = try c.decodeIfPresent(String.self, forKey: .languageCode)
            self.locale = profileId ?? baseCode ?? "und"
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(authors, forKey: .authors)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encode(locale, forKey: .locale)
        try c.encodeIfPresent(coverPath, forKey: .coverPath)
        try c.encode(dateAdded, forKey: .dateAdded)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(origin, forKey: .origin)
        // Only emit collections if non-empty — keeps existing single-book
        // sidecars terse.
        if !collections.isEmpty {
            try c.encode(collections, forKey: .collections)
        }
    }
}
