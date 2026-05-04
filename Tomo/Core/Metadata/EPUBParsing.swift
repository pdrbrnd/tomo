import Foundation

/// Shared XHTML/HTML parser that tries strict XML first, falls back to
/// `documentTidyHTML` for the malformed shapes real-world EPUBs ship with.
/// Used by `EPUBText`, `EPUBNavigation`, and `EPUBSource`.
nonisolated func parseXHTMLOrTidy(_ data: Data) -> XMLDocument? {
    if let strict = try? XMLDocument(data: data, options: []) {
        return strict
    }
    return try? XMLDocument(data: data, options: .documentTidyHTML)
}

/// Best-effort EPUB `<dc:date>` parser. The spec ranges from `2023` through
/// `2023-04-01T12:34:56Z` with many shapes between; we try the most common
/// ISO-8601 forms and a year-only fallback.
nonisolated func parseEPUBDate(_ raw: String) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: trimmed) { return date }
    iso.formatOptions = [.withFullDate]
    if let date = iso.date(from: trimmed) { return date }

    let yearOnly = DateFormatter()
    yearOnly.dateFormat = "yyyy"
    yearOnly.locale = Locale(identifier: "en_US_POSIX")
    yearOnly.timeZone = TimeZone(identifier: "UTC")
    return yearOnly.date(from: trimmed)
}
