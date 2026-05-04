import Foundation
import Testing

@testable import Tomo

@Suite("MetadataSidecar")
struct MetadataSidecarTests {

    @Test func roundTripPreservesAllFields() throws {
        let folder = try makeTempBookFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let book = makeBook(in: folder)
        try MetadataSidecar.write(book, collectionNames: ["Sci-Fi", "To Read"], to: folder)
        let loaded = try MetadataSidecar.read(from: folder)

        #expect(loaded.book.id == book.id)
        #expect(loaded.book.title == book.title)
        #expect(loaded.book.authors == book.authors)
        #expect(loaded.book.year == book.year)
        #expect(loaded.book.locale == book.locale)
        #expect(loaded.book.coverPath == book.coverPath)
        #expect(loaded.book.fileURL.lastPathComponent == book.fileURL.lastPathComponent)
        #expect(loaded.collectionNames == ["Sci-Fi", "To Read"])
    }

    @Test func emptyCollectionsAreOmittedFromJSON() throws {
        let folder = try makeTempBookFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let book = makeBook(in: folder)
        try MetadataSidecar.write(book, collectionNames: [], to: folder)

        let json = try String(
            contentsOf: folder.appending(component: MetadataSidecar.filename), encoding: .utf8)
        #expect(!json.contains("\"collections\""))
    }

    @Test func legacyLanguageProfileIdMapsToLocale() throws {
        let folder = try makeTempBookFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try writeRawSidecar(
            in: folder,
            """
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "title": "Old Book",
              "authors": ["X"],
              "dateAdded": "2024-01-01T00:00:00Z",
              "fileName": "book.epub",
              "origin": { "manualImport": {} },
              "languageProfileId": "pt-PT"
            }
            """)

        let loaded = try MetadataSidecar.read(from: folder)
        #expect(loaded.book.locale == "pt-PT")
    }

    @Test func legacyLanguageCodeMapsToLocale() throws {
        let folder = try makeTempBookFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try writeRawSidecar(
            in: folder,
            """
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "title": "Old Book",
              "authors": ["X"],
              "dateAdded": "2024-01-01T00:00:00Z",
              "fileName": "book.epub",
              "origin": { "manualImport": {} },
              "languageCode": "pt"
            }
            """)

        let loaded = try MetadataSidecar.read(from: folder)
        #expect(loaded.book.locale == "pt")
    }

    @Test func bothLegacyKeysProfileIdWins() throws {
        let folder = try makeTempBookFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try writeRawSidecar(
            in: folder,
            """
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "title": "Old Book",
              "authors": ["X"],
              "dateAdded": "2024-01-01T00:00:00Z",
              "fileName": "book.epub",
              "origin": { "manualImport": {} },
              "languageProfileId": "pt-PT",
              "languageCode": "pt"
            }
            """)

        let loaded = try MetadataSidecar.read(from: folder)
        #expect(loaded.book.locale == "pt-PT")
    }

    @Test func missingIDIsMintedFresh() throws {
        let folder = try makeTempBookFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try writeRawSidecar(
            in: folder,
            """
            {
              "title": "Old Book",
              "authors": ["X"],
              "dateAdded": "2024-01-01T00:00:00Z",
              "fileName": "book.epub",
              "origin": { "manualImport": {} },
              "locale": "und"
            }
            """)

        let loaded = try MetadataSidecar.read(from: folder)
        // Just confirm we got *some* UUID — its value is the random mint.
        #expect(loaded.book.id != UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    }

    @Test func missingCollectionsKeyDecodesAsEmpty() throws {
        let folder = try makeTempBookFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try writeRawSidecar(
            in: folder,
            """
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "title": "Book",
              "authors": ["X"],
              "dateAdded": "2024-01-01T00:00:00Z",
              "fileName": "book.epub",
              "origin": { "manualImport": {} },
              "locale": "en"
            }
            """)

        let loaded = try MetadataSidecar.read(from: folder)
        #expect(loaded.collectionNames.isEmpty)
    }

    @Test func writtenJSONUsesSortedKeys() throws {
        let folder = try makeTempBookFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        try MetadataSidecar.write(makeBook(in: folder), collectionNames: ["A"], to: folder)
        let json = try String(
            contentsOf: folder.appending(component: MetadataSidecar.filename), encoding: .utf8)

        // `authors` should come before `dateAdded` should come before `id`
        // alphabetically — confirm sortedKeys is on so sidecars diff cleanly.
        let authorsIdx = json.range(of: "\"authors\"")?.lowerBound
        let dateIdx = json.range(of: "\"dateAdded\"")?.lowerBound
        let idIdx = json.range(of: "\"id\"")?.lowerBound
        #expect(authorsIdx != nil && dateIdx != nil && idIdx != nil)
        if let a = authorsIdx, let d = dateIdx, let i = idIdx {
            #expect(a < d && d < i)
        }
    }
}

private func makeTempBookFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(component: "TomoSidecarTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeBook(in folder: URL) -> Book {
    Book(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        title: "Frankenstein",
        authors: ["Mary Shelley"],
        year: 1818,
        locale: "en-GB",
        coverPath: "cover.jpg",
        dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
        fileURL: folder.appending(component: "frankenstein.epub"),
        origin: .manualImport
    )
}

private func writeRawSidecar(in folder: URL, _ json: String) throws {
    let url = folder.appending(component: MetadataSidecar.filename)
    try Data(json.utf8).write(to: url, options: .atomic)
}
