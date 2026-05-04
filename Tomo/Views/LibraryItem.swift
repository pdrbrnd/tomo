import Foundation

/// View-layer sum type for grid items. The library grid renders both
/// owned `Book`s and unowned `PluginResult`s as cards in the same lane —
/// this keeps the dispatch local to the grid without polluting the
/// `Book` model with a "remote" variant.
enum LibraryItem: Identifiable {
    case book(Book)
    case source(PluginResult)

    var id: String {
        switch self {
        case .book(let b): return "book:\(b.id)"
        case .source(let r): return "source:\(r.id)"
        }
    }

    /// Display fields lifted to a uniform shape so the card body can render
    /// either kind without branching on the wrapped value.
    var title: String {
        switch self {
        case .book(let b): return b.title
        case .source(let r): return r.title
        }
    }

    var firstAuthor: String? {
        switch self {
        case .book(let b): return b.authors.first
        case .source(let r): return r.authors.first
        }
    }

    var coverURL: URL? {
        switch self {
        case .book(let b): return b.coverURL
        case .source(let r): return r.coverURL
        }
    }

    var isSource: Bool {
        if case .source = self { return true }
        return false
    }
}
