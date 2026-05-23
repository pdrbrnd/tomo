import Foundation
import Testing

@testable import Tomo

@Suite("KindleCoverThumbnail.restoreOverwrittenThumbnails")
struct KindleCoverThumbnailRestoreTests {

    @Test func restoresMissingThumbnail() throws {
        let root = try makeKindleRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 0xAB, count: 1024)
        try seedCache(root: root, name: "thumbnail_X_EBOK_portrait.jpg", bytes: payload)

        let count = KindleCoverThumbnail.restoreOverwrittenThumbnails(volumeURL: root)

        #expect(count == 1)
        let restored = try Data(
            contentsOf: root.appending(path: "system/thumbnails/thumbnail_X_EBOK_portrait.jpg"))
        #expect(restored == payload)
    }

    @Test func restoresSizeMismatchedThumbnail() throws {
        let root = try makeKindleRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = Data(repeating: 0xAB, count: 1024)
        try seedCache(root: root, name: "thumbnail_X_EBOK_portrait.jpg", bytes: real)
        // Stand-in for Amazon's ~60×40 "no image available" placeholder.
        let placeholder = Data(repeating: 0xCD, count: 60)
        try placeholder.write(
            to: root.appending(path: "system/thumbnails/thumbnail_X_EBOK_portrait.jpg"))

        let count = KindleCoverThumbnail.restoreOverwrittenThumbnails(volumeURL: root)

        #expect(count == 1)
        let restored = try Data(
            contentsOf: root.appending(path: "system/thumbnails/thumbnail_X_EBOK_portrait.jpg"))
        #expect(restored == real)
    }

    @Test func leavesMatchingThumbnailUntouched() throws {
        let root = try makeKindleRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 0xAB, count: 1024)
        try seedCache(root: root, name: "thumbnail_X_EBOK_portrait.jpg", bytes: payload)
        try payload.write(
            to: root.appending(path: "system/thumbnails/thumbnail_X_EBOK_portrait.jpg"))
        let mtimeBefore = try mtime(
            of: root.appending(path: "system/thumbnails/thumbnail_X_EBOK_portrait.jpg"))

        let count = KindleCoverThumbnail.restoreOverwrittenThumbnails(volumeURL: root)

        #expect(count == 0)
        let mtimeAfter = try mtime(
            of: root.appending(path: "system/thumbnails/thumbnail_X_EBOK_portrait.jpg"))
        #expect(mtimeBefore == mtimeAfter)
    }

    @Test func noOpWhenCacheMissing() throws {
        let root = try makeKindleRoot(includeCache: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let count = KindleCoverThumbnail.restoreOverwrittenThumbnails(volumeURL: root)

        #expect(count == 0)
    }

    @Test func noOpWhenSystemThumbnailsMissing() throws {
        let root = try makeKindleRoot(includeSystem: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try seedCache(root: root, name: "thumbnail_X_EBOK_portrait.jpg", bytes: Data([0x01]))

        let count = KindleCoverThumbnail.restoreOverwrittenThumbnails(volumeURL: root)

        #expect(count == 0)
    }

    // MARK: helpers

    private func makeKindleRoot(includeCache: Bool = true, includeSystem: Bool = true) throws -> URL {
        let fm = FileManager.default
        let root =
            fm.temporaryDirectory
            .appending(
                component: "tomo-cover-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if includeSystem {
            try fm.createDirectory(
                at: root.appending(path: "system/thumbnails"),
                withIntermediateDirectories: true)
        }
        if includeCache {
            try fm.createDirectory(
                at: root.appending(path: ".tomo/cover-thumbnails"),
                withIntermediateDirectories: true)
        }
        return root
    }

    private func seedCache(root: URL, name: String, bytes: Data) throws {
        let cache = root.appending(path: ".tomo/cover-thumbnails", directoryHint: .isDirectory)
        try bytes.write(to: cache.appending(component: name), options: .atomic)
    }

    private func mtime(of url: URL) throws -> Date {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        guard let date = attrs[.modificationDate] as? Date else {
            throw NSError(domain: "test", code: 0)
        }
        return date
    }
}
