import Foundation
import Testing

@testable import Tomo

@Suite("Kindle.copy")
struct KindleCopyTests {

    @Test func replacesExistingFileOnReSend() async throws {
        let root = try makeKindleVolume()
        defer { try? FileManager.default.removeItem(at: root) }
        guard let kindle = Kindle(volumeURL: root) else {
            Issue.record("Kindle init returned nil for a well-formed volume")
            return
        }

        let source = FileManager.default.temporaryDirectory
            .appending(component: "tomo-kindle-copy-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: source) }

        try "version-1".data(using: .utf8)!.write(to: source, options: .atomic)
        let book = makeBook(fileURL: source)
        let dest = root.appending(path: "documents/\(kindle.deviceFilename(for: book))")

        try await kindle.copy(book)
        #expect(
            try String(contentsOf: dest, encoding: .utf8) == "version-1",
            "first copy didn't land")

        try "version-2".data(using: .utf8)!.write(to: source, options: .atomic)
        try await kindle.copy(book)
        #expect(
            try String(contentsOf: dest, encoding: .utf8) == "version-2",
            "re-send didn't replace existing file")
    }

    // MARK: helpers

    private func makeKindleVolume() throws -> URL {
        let fm = FileManager.default
        let root =
            fm.temporaryDirectory
            .appending(
                component: "tomo-kindle-vol-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "documents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "system"), withIntermediateDirectories: true)
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
            fileURL: fileURL,
            origin: .manualImport
        )
    }
}
