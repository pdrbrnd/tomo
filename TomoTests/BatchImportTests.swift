import Foundation
import Testing
import ZIPFoundation

@testable import Tomo

@MainActor
@Suite("Batch import")
struct BatchImportTests {

    // MARK: - Fingerprint

    @Test func fingerprintIsCaseInsensitive() {
        #expect(
            bookFingerprint(title: "The Hobbit", firstAuthor: "Tolkien")
                == bookFingerprint(title: "the hobbit", firstAuthor: "tolkien"))
    }

    @Test func fingerprintHandlesMissingAuthor() {
        #expect(bookFingerprint(title: "Beowulf", firstAuthor: nil) == "beowulf|")
    }

    @Test func differentBooksFingerprintDifferently() {
        #expect(
            bookFingerprint(title: "Dune", firstAuthor: "Herbert")
                != bookFingerprint(title: "Dune Messiah", firstAuthor: "Herbert"))
    }

    // MARK: - Claims (within-batch dedup mechanism)

    @Test func claimsFirstWinsRepeatLoses() async {
        let claims = FingerprintClaims([:])
        let dune = ImportMatch(title: "Dune", author: "Herbert")
        #expect(await claims.claim("dune|herbert", ref: dune) == nil)
        #expect(await claims.claim("dune|herbert", ref: dune)?.title == "Dune")
        let foundation = ImportMatch(title: "Foundation", author: "Asimov")
        #expect(await claims.claim("foundation|asimov", ref: foundation) == nil)
    }

    @Test func claimsSeededFromLibraryReturnExistingMatch() async {
        let claims = FingerprintClaims(["dune|herbert": ImportMatch(title: "Dune", author: "Herbert")])
        let matched = await claims.claim("dune|herbert", ref: ImportMatch(title: "Dune", author: "F. Herbert"))
        #expect(matched?.title == "Dune")
        #expect(matched?.author == "Herbert")
    }

    // MARK: - prepareImport outcomes

    @Test func importsAReadableEpubAndWritesSidecar() async throws {
        let library = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: library) }
        let epub = try makeEPUB(title: "The Hobbit", author: "Tolkien", language: "en")
        defer { try? FileManager.default.removeItem(at: epub) }

        let outcome = await LibraryImporter.prepareImport(
            from: epub, into: library, profiles: [], claims: nil, allowDuplicate: false)

        guard case .imported(let book) = outcome else {
            Issue.record("expected .imported, got \(outcome)")
            return
        }
        #expect(book.title == "The Hobbit")
        #expect(book.authors == ["Tolkien"])
        // Sidecar written, but caller indexes separately.
        let sidecar = book.fileURL.deletingLastPathComponent()
            .appending(component: "metadata.json")
        #expect(FileManager.default.fileExists(atPath: sidecar.path(percentEncoded: false)))
    }

    @Test func fingerprintMatchAtDifferentPathIsPossibleDuplicate() async throws {
        let library = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: library) }
        // No year → path differs from the seeded library book (which has a
        // year), so this is a possible duplicate, not an exact collision.
        let epub = try makeEPUB(title: "The Hobbit", author: "Tolkien", language: "en")
        defer { try? FileManager.default.removeItem(at: epub) }

        let claims = FingerprintClaims([
            bookFingerprint(title: "The Hobbit", firstAuthor: "Tolkien"):
                ImportMatch(title: "The Hobbit", author: "Tolkien")
        ])
        let outcome = await LibraryImporter.prepareImport(
            from: epub, into: library, profiles: [], claims: claims, allowDuplicate: false)

        guard case .possibleDuplicate(_, let matched) = outcome else {
            Issue.record("expected .possibleDuplicate, got \(outcome)")
            return
        }
        #expect(matched.title == "The Hobbit")
        // Nothing was copied into the library.
        let contents = try FileManager.default.contentsOfDirectory(
            at: library, includingPropertiesForKeys: nil)
        #expect(contents.isEmpty)
    }

    @Test func identicalFileAlreadyOnDiskIsAlreadyInLibrary() async throws {
        let library = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: library) }
        let first = try makeEPUB(title: "Dune", author: "Herbert", language: "en", year: 1965)
        let second = try makeEPUB(title: "Dune", author: "Herbert", language: "en", year: 1965)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let claims = FingerprintClaims([:])
        let a = await LibraryImporter.prepareImport(
            from: first, into: library, profiles: [], claims: claims, allowDuplicate: false)
        let b = await LibraryImporter.prepareImport(
            from: second, into: library, profiles: [], claims: claims, allowDuplicate: false)

        // Same title+author+year → same on-disk path → terminal collision.
        guard case .imported = a else {
            Issue.record("expected first .imported, got \(a)")
            return
        }
        guard case .alreadyInLibrary = b else {
            Issue.record("expected second .alreadyInLibrary, got \(b)")
            return
        }
    }

    @Test func differentEditionsInOneBatchArePossibleDuplicate() async throws {
        let library = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: library) }
        let first = try makeEPUB(title: "Dune", author: "Herbert", language: "en", year: 1965)
        let second = try makeEPUB(title: "Dune", author: "Herbert", language: "en", year: 1990)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let claims = FingerprintClaims([:])
        let a = await LibraryImporter.prepareImport(
            from: first, into: library, profiles: [], claims: claims, allowDuplicate: false)
        let b = await LibraryImporter.prepareImport(
            from: second, into: library, profiles: [], claims: claims, allowDuplicate: false)

        // Same title+author, different year → different path → flagged, not blocked.
        guard case .imported = a else {
            Issue.record("expected first .imported, got \(a)")
            return
        }
        guard case .possibleDuplicate = b else {
            Issue.record("expected second .possibleDuplicate, got \(b)")
            return
        }
    }

    @Test func importAnywayBypassesDedup() async throws {
        let library = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: library) }
        let epub = try makeEPUB(title: "The Hobbit", author: "Tolkien", language: "en")
        defer { try? FileManager.default.removeItem(at: epub) }

        let claims = FingerprintClaims([
            bookFingerprint(title: "The Hobbit", firstAuthor: "Tolkien"):
                ImportMatch(title: "The Hobbit", author: "Tolkien")
        ])
        let outcome = await LibraryImporter.prepareImport(
            from: epub, into: library, profiles: [], claims: claims, allowDuplicate: true)

        guard case .imported = outcome else {
            Issue.record("expected .imported (dedup bypassed), got \(outcome)")
            return
        }
    }

    @Test func unreadableFileFailsWithoutThrowing() async throws {
        let library = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: library) }
        let junk = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).epub")
        try Data("not a zip".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }

        let outcome = await LibraryImporter.prepareImport(
            from: junk, into: library, profiles: [], claims: nil, allowDuplicate: false)

        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
    }

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Minimal EPUB 3: mimetype + container.xml + OEBPS/content.opf + one doc.
    private func makeEPUB(title: String, author: String, language: String, year: Int? = nil)
        throws -> URL
    {
        let dateTag = year.map { "<dc:date>\($0)</dc:date>" } ?? ""
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).epub")
        let archive = try Archive(url: url, accessMode: .create)

        func add(_ name: String, _ data: Data, compression: CompressionMethod = .deflate) throws {
            try archive.addEntry(
                with: name, type: .file, uncompressedSize: Int64(data.count),
                compressionMethod: compression
            ) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }

        try add("mimetype", Data("application/epub+zip".utf8), compression: .none)
        try add(
            "META-INF/container.xml",
            Data(
                """
                <?xml version="1.0"?>
                <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                  <rootfiles>
                    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
                  </rootfiles>
                </container>
                """.utf8))
        try add(
            "OEBPS/content.opf",
            Data(
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
                  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:title>\(title)</dc:title>
                    <dc:identifier id="id">x</dc:identifier>
                    <dc:creator>\(author)</dc:creator>
                    <dc:language>\(language)</dc:language>
                    \(dateTag)
                  </metadata>
                  <manifest>
                    <item id="t" href="t.xhtml" media-type="application/xhtml+xml"/>
                  </manifest>
                  <spine>
                    <itemref idref="t"/>
                  </spine>
                </package>
                """.utf8))
        try add("OEBPS/t.xhtml", Data("<html><body>hi</body></html>".utf8))
        return url
    }
}
