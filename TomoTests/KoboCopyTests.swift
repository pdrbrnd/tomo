import Foundation
import Testing

@testable import Tomo

@Suite("Kobo.copy")
struct KoboCopyTests {

    @Test func replacesExistingFileOnReSend() async throws {
        let root = try makeKoboVolume()
        defer { try? FileManager.default.removeItem(at: root) }
        guard let kobo = Kobo(volumeURL: root) else {
            Issue.record("Kobo init returned nil for a well-formed volume")
            return
        }

        let source = FileManager.default.temporaryDirectory
            .appending(component: "tomo-kobo-copy-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: source) }

        try "version-1".data(using: .utf8)!.write(to: source, options: .atomic)
        let book = makeBook(fileURL: source)
        // Kobo writes at volume root, not a `documents/` subfolder.
        let dest = root.appending(component: kobo.deviceFilename(for: book))

        try await kobo.copy(book)
        #expect(
            try String(contentsOf: dest, encoding: .utf8) == "version-1",
            "first copy didn't land")

        try "version-2".data(using: .utf8)!.write(to: source, options: .atomic)
        try await kobo.copy(book)
        #expect(
            try String(contentsOf: dest, encoding: .utf8) == "version-2",
            "re-send didn't replace existing file")
    }

    // MARK: helpers

    private func makeKoboVolume() throws -> URL {
        let fm = FileManager.default
        let root =
            fm.temporaryDirectory
            .appending(
                component: "tomo-kobo-vol-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: ".kobo"), withIntermediateDirectories: true)
        return root
    }

    private func makeBook(fileURL: URL) -> Book {
        Book(
            id: UUID(),
            title: "T",
            authors: [],
            year: nil,
            locale: "und",
            coverPath: nil,
            dateAdded: .now,
            fileURL: fileURL
        )
    }
}
