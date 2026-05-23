import Foundation
import Testing

@testable import Tomo

@Suite("Kindle.isSystemFile")
struct KindleSystemFilesTests {

    private func kindle() throws -> Kindle {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appending(
                component: "tomo-kindle-vol-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "documents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "system"), withIntermediateDirectories: true)
        guard let device = Kindle(volumeURL: root) else {
            throw KindleTestError.initFailed
        }
        return device
    }

    private enum KindleTestError: Error { case initFailed }

    // MARK: - System files (hidden)

    @Test func hidesMyClippings() throws {
        let k = try kindle()
        #expect(k.isSystemFile(relativePath: "My Clippings.txt"))
        #expect(k.isSystemFile(relativePath: "my clippings.txt"))  // case-insensitive
    }

    @Test func hidesAmazonGuides() throws {
        let k = try kindle()
        #expect(k.isSystemFile(relativePath: "Kindle User's Guide.azw"))
        #expect(k.isSystemFile(relativePath: "User's Guide.pdf"))
        #expect(k.isSystemFile(relativePath: "Welcome.azw"))
        #expect(k.isSystemFile(relativePath: "Getting Started.azw"))
        #expect(k.isSystemFile(relativePath: "Quick Tour.azw"))
    }

    @Test func hidesOxfordDictionaries() throws {
        let k = try kindle()
        #expect(k.isSystemFile(relativePath: "Oxford Dictionary of English.azw"))
        #expect(k.isSystemFile(relativePath: "New Oxford American Dictionary.azw"))
        #expect(k.isSystemFile(relativePath: "The New Oxford American Dictionary.azw"))
    }

    @Test func hidesLocalizedDictionaries() throws {
        let k = try kindle()
        #expect(k.isSystemFile(relativePath: "Dicionário de Português.azw"))
        #expect(k.isSystemFile(relativePath: "Larousse Dictionnaire de Français.azw"))
        #expect(k.isSystemFile(relativePath: "Duden Wörterbuch.azw"))
        #expect(k.isSystemFile(relativePath: "Diccionario de la Real Academia.azw"))
    }

    // MARK: - User books (visible)

    @Test func keepsUserBookWithDictionaryInTitle() throws {
        let k = try kindle()
        // No Amazon-publisher token → user book.
        #expect(!k.isSystemFile(relativePath: "The Devil's Dictionary.azw3"))
        #expect(!k.isSystemFile(relativePath: "Mexican Slang Dictionary.epub"))
    }

    @Test func keepsBookInSubfolder() throws {
        let k = try kindle()
        #expect(!k.isSystemFile(relativePath: "Sci-Fi/Foundation.azw3"))
    }

    @Test func keepsArbitraryUserBook() throws {
        let k = try kindle()
        #expect(!k.isSystemFile(relativePath: "tolkien-the-hobbit-1937.azw3"))
        #expect(!k.isSystemFile(relativePath: "asimov-foundation-1951.mobi"))
    }
}
