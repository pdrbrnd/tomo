import Foundation
import Testing

@testable import Tomo

@Suite("Kobo.init")
struct KoboDetectionTests {

    @Test func initSucceedsForVolumeWithDotKobo() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appending(path: ".kobo"), withIntermediateDirectories: true)

        #expect(Kobo(volumeURL: root) != nil)
    }

    @Test func initFailsForVolumeWithoutDotKobo() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // Empty volume — no .kobo/, no anything Kobo-shaped.

        #expect(Kobo(volumeURL: root) == nil)
    }

    @Test func initFailsForKindleVolume() throws {
        // Guard against false positives if the scanner ever flips its
        // device-init order — Kobo must not claim a Kindle.
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appending(path: "documents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appending(path: "system"), withIntermediateDirectories: true)

        #expect(Kobo(volumeURL: root) == nil)
    }

    private func makeTempDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(
                component: "tomo-kobo-detect-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
