import Foundation

/// On-disk store for collection definitions. Lives at
/// `<library>/.tomo/collections.json`. Pairs with the per-book sidecar's
/// collection-names array: this file owns identity (id, sortOrder,
/// dateCreated), the sidecar owns membership (by name).
///
/// Together they make the library folder fully self-describing — point a
/// fresh install at the same folder and the entire organization comes back.
nonisolated enum CollectionsFile {
    static let directoryName = ".tomo"
    static let filename = "collections.json"
    static let currentVersion = 1

    static func url(in libraryFolder: URL) -> URL {
        libraryFolder
            .appending(component: directoryName, directoryHint: .isDirectory)
            .appending(component: filename)
    }

    static func exists(in libraryFolder: URL) -> Bool {
        FileManager.default.fileExists(atPath: url(in: libraryFolder).path(percentEncoded: false))
    }

    /// Reads the collections file. Missing file → `nil`, distinct from
    /// "present-and-empty" (`[]`); the migration path needs that distinction
    /// to decide whether to seed from a legacy DB.
    static func read(in libraryFolder: URL) throws -> [Collection]? {
        let url = url(in: libraryFolder)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(Payload.self, from: data)
        // Single shape for v1. Add `switch payload.version` here when v2 lands.
        return payload.collections
    }

    /// Writes atomically. Creates the `.tomo` directory if needed.
    static func write(_ collections: [Collection], in libraryFolder: URL) throws {
        let dirURL = libraryFolder.appending(
            component: directoryName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload = Payload(version: currentVersion, collections: collections)
        let data = try encoder.encode(payload)
        try data.write(to: url(in: libraryFolder), options: .atomic)
    }

    private struct Payload: Codable {
        let version: Int
        let collections: [Collection]
    }
}
