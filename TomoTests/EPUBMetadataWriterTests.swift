import AZW3
import Foundation
import Testing
import ZIPFoundation

@testable import Tomo

@MainActor @Suite struct EPUBMetadataWriterTests {

    private func makeBook(
        title: String,
        authors: [String],
        locale: String,
        fileURL: URL
    ) -> Book {
        Book(
            id: UUID(),
            title: title,
            authors: authors,
            year: nil,
            locale: locale,
            coverPath: nil,
            dateAdded: Date(),
            fileURL: fileURL
        )
    }

    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func rewritesChangedFields() throws {
        let source = try MetaEPUBFixture.minimal(
            title: "Old Title", authors: ["Old Author"], language: "en",
            spineDocs: [("ch1.xhtml", "<p>Body</p>")]
        )
        defer { try? FileManager.default.removeItem(at: source) }
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let book = makeBook(
            title: "New Title", authors: ["Author One", "Author Two"],
            locale: "pt-PT", fileURL: source)

        let corrected = try #require(
            EPUBMetadataWriter.metadataCorrectedCopy(of: source, for: book, into: scratch))

        // The corrected copy re-parses to the edited values and still opens
        // (mimetype intact / valid archive).
        let epub = try EPUBArchive.open(corrected)
        #expect(epub.opf.title == "New Title")
        #expect(epub.opf.authors == ["Author One", "Author Two"])
        #expect(epub.opf.language == "pt-PT")

        // The library original is untouched.
        let original = try EPUBArchive.open(source)
        #expect(original.opf.title == "Old Title")
        #expect(original.opf.authors == ["Old Author"])
    }

    @Test func returnsNilWhenNothingChanged() throws {
        let source = try MetaEPUBFixture.minimal(
            title: "Same", authors: ["Same Author"], language: "en",
            spineDocs: [("ch1.xhtml", "<p>Body</p>")]
        )
        defer { try? FileManager.default.removeItem(at: source) }
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let book = makeBook(
            title: "Same", authors: ["Same Author"], locale: "en", fileURL: source)

        #expect(EPUBMetadataWriter.metadataCorrectedCopy(of: source, for: book, into: scratch) == nil)
    }

    @Test func absentLanguageEqualsUndDoesNotRewrite() throws {
        let source = try MetaEPUBFixture.minimal(
            title: "T", authors: ["A"], language: nil,
            spineDocs: [("ch1.xhtml", "<p>Body</p>")]
        )
        defer { try? FileManager.default.removeItem(at: source) }
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let book = makeBook(title: "T", authors: ["A"], locale: "und", fileURL: source)

        #expect(EPUBMetadataWriter.metadataCorrectedCopy(of: source, for: book, into: scratch) == nil)
    }

    @Test func nilForUnparseableEpub() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).epub")
        try Data("not a zip".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let book = makeBook(title: "X", authors: ["Y"], locale: "en", fileURL: source)

        // Best-effort: no throw, just nil so delivery falls back to the original.
        #expect(EPUBMetadataWriter.metadataCorrectedCopy(of: source, for: book, into: scratch) == nil)
    }

    @Test func preservesFileAsOnUnchangedAuthors() throws {
        // Only the title changes; the creator (with file-as) must be left alone.
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>Old Title</dc:title>
                <dc:identifier id="id">x</dc:identifier>
                <dc:creator opf:role="aut" opf:file-as="Le Guin, Ursula K.">Ursula K. Le Guin</dc:creator>
                <dc:language>en</dc:language>
              </metadata>
              <manifest>
                <item id="item0" href="ch1.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine>
                <itemref idref="item0"/>
              </spine>
            </package>
            """
        let body = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>x</title></head><body><p>B</p></body></html>
            """
        let source = try MetaEPUBFixture.custom(opf: opf, files: ["ch1.xhtml": Data(body.utf8)])
        defer { try? FileManager.default.removeItem(at: source) }
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let book = makeBook(
            title: "New Title", authors: ["Ursula K. Le Guin"], locale: "en", fileURL: source)

        let corrected = try #require(
            EPUBMetadataWriter.metadataCorrectedCopy(of: source, for: book, into: scratch))

        let epub = try EPUBArchive.open(corrected)
        #expect(epub.opf.title == "New Title")
        #expect(epub.opf.authors == ["Ursula K. Le Guin"])
        // The untouched creator keeps its file-as sort key.
        let opfData = try #require(epub.data(at: epub.opfPath))
        let opfText = String(decoding: opfData, as: UTF8.self)
        #expect(opfText.contains("Le Guin, Ursula K."))
    }

    @Test func overrideAppliesInEPUBSource() throws {
        let source = try MetaEPUBFixture.minimal(
            title: "Old", authors: ["Old"], language: "en",
            spineDocs: [("ch1.xhtml", "<p>Body</p>")]
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let manifest = try EPUBSource.read(
            from: source,
            metadata: .init(title: "New", authors: ["A", "B"], language: "pt-BR")
        )
        #expect(manifest.title == "New")
        #expect(manifest.authors == ["A", "B"])
        #expect(manifest.language == "pt-BR")
    }
}

// MARK: - Fixture builder
//
// Local copy, mirroring the per-suite fixtures in EPUBSourceTests /
// EPUBToAZW3ConverterTests (Swift Testing has no clean cross-suite shared
// fixture story yet; consolidate when the test target gets a Helpers/ folder).

private enum MetaEPUBFixture {

    static func minimal(
        title: String,
        authors: [String],
        language: String?,
        spineDocs: [(href: String, body: String)]
    ) throws -> URL {
        let langTag = language.map { "<dc:language>\($0)</dc:language>" } ?? ""
        let creators =
            authors
            .map { "<dc:creator>\($0)</dc:creator>" }
            .joined(separator: "\n    ")
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>\(title)</dc:title>
                <dc:identifier id="id">x</dc:identifier>
                \(creators)
                \(langTag)
              </metadata>
              <manifest>
                <item id="item0" href="\(spineDocs[0].href)" media-type="application/xhtml+xml"/>
              </manifest>
              <spine>
                <itemref idref="item0"/>
              </spine>
            </package>
            """
        var files: [String: Data] = [:]
        for doc in spineDocs {
            let xhtml = """
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml"><head><title>x</title></head><body>\(doc.body)</body></html>
                """
            files[doc.href] = Data(xhtml.utf8)
        }
        return try custom(opf: opf, files: files)
    }

    /// Builds a ZIP with `mimetype`, `META-INF/container.xml`,
    /// `OEBPS/content.opf`, and the supplied `files` (relative to OEBPS).
    static func custom(opf: String, files: [String: Data]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).epub")
        let archive = try Archive(url: url, accessMode: .create)

        let mimetype = Data("application/epub+zip".utf8)
        try archive.addEntry(
            with: "mimetype", type: .file, uncompressedSize: Int64(mimetype.count),
            compressionMethod: .none,
            provider: { position, size in
                mimetype.subdata(in: Int(position)..<Int(position) + size)
            }
        )
        let container = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """.utf8)
        try addEntry(archive: archive, path: "META-INF/container.xml", data: container)
        try addEntry(archive: archive, path: "OEBPS/content.opf", data: Data(opf.utf8))
        for (relPath, data) in files {
            try addEntry(archive: archive, path: "OEBPS/\(relPath)", data: data)
        }
        return url
    }

    private static func addEntry(archive: Archive, path: String, data: Data) throws {
        try archive.addEntry(
            with: path, type: .file, uncompressedSize: Int64(data.count),
            compressionMethod: .deflate,
            provider: { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        )
    }
}
