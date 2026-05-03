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
    var languageCode: String
    var coverPath: String?
    var dateAdded: Date
    var fileName: String
    var origin: BookOrigin

    init(book: Book) {
        self.title = book.title
        self.authors = book.authors
        self.year = book.year
        self.languageCode = book.languageCode
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
            languageCode: languageCode,
            coverPath: coverPath,
            dateAdded: dateAdded,
            fileURL: folder.appending(component: fileName),
            origin: origin
        )
    }
}
