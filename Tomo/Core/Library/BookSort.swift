import Foundation

/// User-pickable sort order for the library grid. Persisted via
/// `@AppStorage` in `LibraryView`; the menu bar's "View → Sort By"
/// submenu is the canonical way to change it.
nonisolated enum BookSort: String, CaseIterable, Identifiable {
    case title
    case author
    case year
    case dateAdded

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "Title"
        case .author: return "Author"
        case .year: return "Year"
        case .dateAdded: return "Date Added"
        }
    }
}

extension Sequence where Element == Book {
    /// Returns the books sorted by `key`, ascending or descending. Books
    /// missing the sort field (no year, no authors) fall to the end
    /// regardless of direction — same convention Finder uses for missing
    /// metadata. Ties break on title so the order is stable.
    func sorted(by key: BookSort, ascending: Bool) -> [Book] {
        sorted { lhs, rhs in
            compare(lhs, rhs, by: key, ascending: ascending)
        }
    }

    private func compare(_ lhs: Book, _ rhs: Book, by key: BookSort, ascending: Bool) -> Bool {
        switch key {
        case .title:
            return stringCompare(lhs.title, rhs.title, ascending: ascending)
        case .author:
            return stringCompare(
                lhs.authors.first ?? "",
                rhs.authors.first ?? "",
                ascending: ascending,
                missingFirst: lhs.authors.isEmpty,
                missingSecond: rhs.authors.isEmpty
            )
        case .year:
            return optionalCompare(lhs.year, rhs.year, ascending: ascending) {
                stringCompare(lhs.title, rhs.title, ascending: true)
            }
        case .dateAdded:
            if lhs.dateAdded == rhs.dateAdded {
                return stringCompare(lhs.title, rhs.title, ascending: true)
            }
            return ascending ? lhs.dateAdded < rhs.dateAdded : lhs.dateAdded > rhs.dateAdded
        }
    }

    private func stringCompare(
        _ a: String,
        _ b: String,
        ascending: Bool,
        missingFirst: Bool = false,
        missingSecond: Bool = false
    ) -> Bool {
        // Missing values always sort last, irrespective of direction.
        if missingFirst != missingSecond { return missingSecond }
        let result = a.localizedStandardCompare(b)
        if result == .orderedSame { return false }
        return ascending ? result == .orderedAscending : result == .orderedDescending
    }

    private func optionalCompare<T: Comparable>(
        _ a: T?,
        _ b: T?,
        ascending: Bool,
        tieBreaker: () -> Bool
    ) -> Bool {
        switch (a, b) {
        case (nil, nil): return tieBreaker()
        case (nil, _): return false  // nil always last
        case (_, nil): return true
        case (let a?, let b?):
            if a == b { return tieBreaker() }
            return ascending ? a < b : a > b
        }
    }
}
