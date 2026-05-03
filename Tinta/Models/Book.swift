import Foundation

nonisolated struct Book: Sendable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var authors: [String]
    var year: Int?
    var languageCode: String           // base language declared by the EPUB; "und" when unknown
    var languageProfileId: String?     // classifier verdict, e.g. "pt-PT"
    var languageConfidence: Double?    // 0...1, normalized
    var coverPath: String?             // relative to the book's folder
    var dateAdded: Date
    var fileURL: URL                   // absolute path to primary file
    var origin: BookOrigin

    var coverURL: URL? {
        guard let coverPath else { return nil }
        return fileURL.deletingLastPathComponent().appending(component: coverPath)
    }
}

nonisolated enum BookOrigin: Codable, Sendable, Equatable, Hashable {
    case manualImport
    case source(id: String, ref: String?)
}
