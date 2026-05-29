import Foundation

/// Where the user left off in a book. EPUB uses `spineIndex` (which chapter)
/// + `scrollFraction` (how far down it, 0…1); PDF uses `pageIndex`. The
/// fields are independent — a given book only reads back the ones its format
/// uses.
///
/// This is local, ephemeral state, deliberately kept *out* of the portable
/// library: not in the `metadata.json` sidecar (it isn't part of book
/// identity and would trigger an iCloud write on every close) and not in the
/// SQLite index (that's disposable and rebuilt from sidecars; position can't
/// be rebuilt). It lives in `UserDefaults`, consistent with "internal state
/// never in iCloud".
struct ReadingPosition: Codable, Sendable, Equatable {
    var spineIndex: Int = 0
    var scrollFraction: Double = 0
    var pageIndex: Int = 0
}

enum ReadingPositionStore {
    private static func key(for bookID: UUID) -> String {
        "reading-position.\(bookID.uuidString)"
    }

    static func position(for bookID: UUID) -> ReadingPosition? {
        guard let data = UserDefaults.standard.data(forKey: key(for: bookID)) else {
            return nil
        }
        return try? JSONDecoder().decode(ReadingPosition.self, from: data)
    }

    static func save(_ position: ReadingPosition, for bookID: UUID) {
        guard let data = try? JSONEncoder().encode(position) else { return }
        UserDefaults.standard.set(data, forKey: key(for: bookID))
    }
}
