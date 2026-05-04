import Foundation

/// User-defined grouping of books. Many-to-many: a book can be in any number
/// of collections, a collection holds any number of books.
///
/// Collections live in the index (SQLite) for query efficiency, and their
/// membership is mirrored in each book's sidecar by **name** — so rebuilding
/// the index from sidecars reconstructs collections without losing groupings.
nonisolated struct Collection: Sendable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var sortOrder: Int
    var dateCreated: Date
}
