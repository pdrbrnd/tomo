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

    var year: Int? {
        let raw: Int?
        switch self {
        case .book(let b): raw = b.year
        case .source(let r): raw = r.year
        }
        // Plugins occasionally surface `0` or negative years as a stand-in
        // for "unknown"; treat those as missing so the row doesn't show "0"
        // where a year would go.
        guard let raw, raw > 0 else { return nil }
        return raw
    }

    /// BCP 47 tag (books) or plugin-provided language string (sources).
    /// Returns nil for the special "und" tag or empty strings — callers
    /// can skip rendering instead of showing a meaningless badge.
    var localeTag: String? {
        let raw: String
        switch self {
        case .book(let b): raw = b.locale
        case .source(let r): raw = r.language
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("und") == .orderedSame {
            return nil
        }
        return trimmed
    }

    /// Uppercased format identifier (e.g. "EPUB"). Books derive from the
    /// file's extension; sources carry it as a declared field.
    var format: String? {
        let raw: String
        switch self {
        case .book(let b): raw = b.fileURL.pathExtension
        case .source(let r): raw = r.format
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.uppercased()
    }

    /// Plugin-declared size in bytes. Library books don't carry this — the
    /// file system has it, but reading it eagerly risks waking up iCloud
    /// placeholders, so we don't.
    var sizeBytes: Int? {
        switch self {
        case .book: return nil
        case .source(let r): return r.sizeBytes
        }
    }

    /// Publisher (sources only — surfaced from the plugin's freeform metadata
    /// bag under any `publisher`-like key). The Book model doesn't carry a
    /// publisher field today, so library rows return nil here.
    ///
    /// Falsy / junk values get dropped: empty strings, literal "0", and
    /// pure-numeric values (some plugins duplicate the year into the
    /// publisher slot — "1959" sitting in publisher isn't a publisher name).
    var publisher: String? {
        guard case .source(let r) = self else { return nil }
        let needle = "publisher"
        let field = r.metadata.first { $0.key.lowercased() == needle }
        guard let raw = field?.value.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            raw != "0"
        else { return nil }
        // All-digits → year masquerading as publisher, drop it.
        if raw.allSatisfy(\.isNumber) { return nil }
        return raw
    }
}
