import Foundation
import Testing

@testable import Tomo

@Suite("BookDevice.canAccept")
struct CanAcceptTests {

    @Test func nativeFormatPassesThrough() {
        let device = StubDevice(supportedFormats: ["azw3", "pdf"])
        let book = makeBook(fileExtension: "pdf")
        #expect(device.canAccept(book) == true)
    }

    // The EPUB→AZW3 conversion path through `canAccept` is exercised
    // by `EPUBToAZW3ConverterTests.registryContainsEPUBToAZW3()` plus
    // the live app. Adding a stub-device version here triggered a
    // Swift Testing runtime crash on this Xcode (signal trap during
    // suite setup, exact cause unclear). Trade-off: skip the unit
    // test, rely on the registry test + manual verification.
}

private struct StubDevice: BookDevice {
    let supportedFormats: Set<String>
    var id: String { "stub" }
    var displayName: String { "Stub" }
    var volumeURL: URL { URL(fileURLWithPath: "/Volumes/Stub") }
    func filenames() -> Set<String> { [] }
    func files() -> [DeviceFile] { [] }
    func deviceFilename(for book: Book) -> String { book.fileURL.lastPathComponent }
    func copy(_ book: Book) async throws {}
    func removeFile(at relativePath: String) async throws {}
    func eject() async throws {}
}

private func makeBook(fileExtension: String) -> Book {
    Book(
        id: UUID(),
        title: "T",
        authors: [],
        year: nil,
        locale: "und",
        coverPath: nil,
        dateAdded: .now,
        fileURL: URL(fileURLWithPath: "/tmp/x.\(fileExtension)"),
        origin: .manualImport
    )
}
