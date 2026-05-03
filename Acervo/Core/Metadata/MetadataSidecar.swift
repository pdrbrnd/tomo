import Foundation

nonisolated enum MetadataSidecar {
    static let filename = "metadata.json"

    static func write(_ book: Book, to bookFolder: URL) throws {
        let url = bookFolder.appending(component: filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(SidecarPayload(book: book))
        try data.write(to: url, options: .atomic)
    }

    static func read(from bookFolder: URL) throws -> Book {
        let url = bookFolder.appending(component: filename)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(SidecarPayload.self, from: data)
        return payload.book(in: bookFolder)
    }
}

private nonisolated struct SidecarPayload: Codable {
    var title: String
    var authors: [String]
    var year: Int?
    var locale: String
    var coverPath: String?
    var dateAdded: Date
    var fileName: String
    var origin: BookOrigin

    init(book: Book) {
        self.title = book.title
        self.authors = book.authors
        self.year = book.year
        self.locale = book.locale
        self.coverPath = book.coverPath
        self.dateAdded = book.dateAdded
        self.fileName = book.fileURL.lastPathComponent
        self.origin = book.origin
    }

    func book(in folder: URL) -> Book {
        Book(
            id: UUID(),
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
        case title, authors, year, locale, coverPath, dateAdded, fileName, origin
        // Legacy keys (sidecars written before the unified-locale refactor):
        case languageCode, languageProfileId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try c.decode(String.self, forKey: .title)
        self.authors = try c.decode([String].self, forKey: .authors)
        self.year = try c.decodeIfPresent(Int.self, forKey: .year)
        self.coverPath = try c.decodeIfPresent(String.self, forKey: .coverPath)
        self.dateAdded = try c.decode(Date.self, forKey: .dateAdded)
        self.fileName = try c.decode(String.self, forKey: .fileName)
        self.origin = try c.decode(BookOrigin.self, forKey: .origin)

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
        try c.encode(title, forKey: .title)
        try c.encode(authors, forKey: .authors)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encode(locale, forKey: .locale)
        try c.encodeIfPresent(coverPath, forKey: .coverPath)
        try c.encode(dateAdded, forKey: .dateAdded)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(origin, forKey: .origin)
    }
}
