import Foundation

/// User-defined grouping of books. Many-to-many: a book can be in any number
/// of collections, a collection holds any number of books.
///
/// **Disk truth:** collection *definitions* (id, name, sortOrder, dateCreated)
/// live in `<library>/.tomo/collections.json`; collection *membership* lives
/// in each book's sidecar (by name). The SQLite index is a derived cache,
/// rebuilt from these two on every sync.
nonisolated struct Collection: Sendable, Identifiable, Equatable, Hashable, Codable {
    let id: UUID
    var name: String
    var sortOrder: Int
    var dateCreated: Date
}
