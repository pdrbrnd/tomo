import Foundation

/// A book's membership in a published series. Position remains text so EPUB
/// numbering such as `2.2.1` is preserved exactly as supplied.
nonisolated struct BookSeries: Codable, Hashable, Sendable {
    var name: String
    var position: String?

    /// Reading order within a series. Numeric positions sort first, in
    /// numeric order; non-numeric ones (`2a`) after them, missing ones last.
    static func positionComesBefore(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let left = normalizedPosition(lhs) else { return false }
        guard let right = normalizedPosition(rhs) else { return true }
        switch (numericKey(left), numericKey(right)) {
        case let (leftKey?, rightKey?): return leftKey.lexicographicallyPrecedes(rightKey)
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    /// Whether `value` is a number the EPUB `group-position` / Calibre
    /// `series_index` fields can carry: digits, optionally dot-separated.
    static func isStandardPosition(_ value: String) -> Bool {
        guard let normalized = normalizedPosition(value) else { return false }
        return numericKey(normalized) != nil
    }

    /// Position as read from an EPUB: trimmed, with whole numbers written as
    /// decimals (Calibre's `5.0`) shortened to `5`. Nil when empty.
    static func importedPosition(_ raw: String?) -> String? {
        guard let position = normalizedPosition(raw) else { return nil }
        let parts = position.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 2, isStandardPosition(position), parts[1].allSatisfy({ $0 == "0" }) {
            return String(parts[0])
        }
        return position
    }

    private static func normalizedPosition(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Sort key for a numeric position. One dot reads as a decimal (Calibre's
    /// `1.5` between books 1 and 2, so `1.25 < 1.5`); more than one as
    /// hierarchical numbering (`2.2.1`). Nil when not numeric.
    private static func numericKey(_ position: String) -> [Double]? {
        let parts = position.split(separator: ".", omittingEmptySubsequences: false)
        let allDigits = parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
        guard allDigits else { return nil }
        if parts.count <= 2 {
            return Double(position).map { [$0] }
        }
        return parts.compactMap { Double($0) }
    }
}
