import AZW3
import AppKit
import Foundation
import Testing
import ZIPFoundation

@testable import Tomo

@MainActor @Suite struct EPUBMetadataWriterTests {

    private func makeBook(
        title: String,
        authors: [String],
        locale: String,
        series: [BookSeries] = [],
        metadataVersion: Int = Book.currentMetadataVersion,
        fileURL: URL
    ) -> Book {
        Book(
            id: UUID(),
            title: title,
            authors: authors,
            series: series,
            year: nil,
            locale: locale,
            coverPath: nil,
            dateAdded: Date(),
            fileURL: fileURL,
            metadataVersion: metadataVersion
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

    // MARK: - Series

    private static let epub3Series = """
        <meta property="belongs-to-collection" id="c1">Saga</meta>
        <meta refines="#c1" property="collection-type">series</meta>
        <meta refines="#c1" property="group-position">5.0</meta>
        <meta property="belongs-to-collection" id="c2">Publisher Set</meta>
        """

    private static let calibreSeries = """
        <meta name="calibre:series" content="Saga"/>
        <meta name="calibre:series_index" content="2.0"/>
        """

    /// Book whose title/authors/language match `seriesEPUB`, so only series
    /// can trigger a rewrite.
    private func matchingBook(
        series: [BookSeries],
        metadataVersion: Int = Book.currentMetadataVersion,
        fileURL: URL
    ) -> Book {
        makeBook(
            title: "Title", authors: ["Author"], locale: "en", series: series,
            metadataVersion: metadataVersion, fileURL: fileURL)
    }

    @Test func parsesEPUB3SeriesAndSkipsOtherCollections() throws {
        let source = try MetaEPUBFixture.series(version: "3.0", metadata: Self.epub3Series)
        defer { try? FileManager.default.removeItem(at: source) }

        let epub = try EPUBArchive.open(source)
        #expect(epub.opf.series == [BookSeries(name: "Saga", position: "5")])
    }

    @Test func parsesCalibreSeriesFallback() throws {
        let source = try MetaEPUBFixture.series(version: "2.0", metadata: Self.calibreSeries)
        defer { try? FileManager.default.removeItem(at: source) }

        let epub = try EPUBArchive.open(source)
        #expect(epub.opf.series == [BookSeries(name: "Saga", position: "2")])
    }

    @Test func removedSeriesIsStrippedFromCopy() throws {
        let source = try MetaEPUBFixture.series(version: "3.0", metadata: Self.epub3Series)
        defer { try? FileManager.default.removeItem(at: source) }
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let book = matchingBook(series: [], fileURL: source)
        let corrected = try #require(
            EPUBMetadataWriter.metadataCorrectedCopy(of: source, for: book, into: scratch))

        let epub = try EPUBArchive.open(corrected)
        #expect(epub.opf.series.isEmpty)
        let opfText = String(decoding: try #require(epub.data(at: epub.opfPath)), as: UTF8.self)
        #expect(opfText.contains("Publisher Set"))
    }

    @Test func unmigratedBookKeepsEPUBSeries() throws {
        let source = try MetaEPUBFixture.series(version: "3.0", metadata: Self.epub3Series)
        defer { try? FileManager.default.removeItem(at: source) }
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Empty because Tomo hasn't read the series yet, not because the
        // user removed it.
        let book = matchingBook(series: [], metadataVersion: 1, fileURL: source)
        #expect(EPUBMetadataWriter.metadataCorrectedCopy(of: source, for: book, into: scratch) == nil)
    }

    @Test func rewritesEPUB3SeriesAndKeepsOtherCollections() throws {
        let source = try MetaEPUBFixture.series(version: "3.0", metadata: Self.epub3Series)
        defer { try? FileManager.default.removeItem(at: source) }
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let book = matchingBook(series: [BookSeries(name: "Other Saga", position: "1.5")], fileURL: source)
        let corrected = try #require(
            EPUBMetadataWriter.metadataCorrectedCopy(of: source, for: book, into: scratch))

        let epub = try EPUBArchive.open(corrected)
        #expect(epub.opf.series == [BookSeries(name: "Other Saga", position: "1.5")])
        let opfText = String(decoding: try #require(epub.data(at: epub.opfPath)), as: UTF8.self)
        #expect(opfText.contains("Publisher Set"))
        #expect(!opfText.contains(">Saga<"))
    }

    @Test func rewritesEPUB2SeriesAsCalibreTags() throws {
        let source = try MetaEPUBFixture.series(version: "2.0", metadata: Self.calibreSeries)
        defer { try? FileManager.default.removeItem(at: source) }
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let book = matchingBook(
            series: [BookSeries(name: "Saga", position: "3"), BookSeries(name: "Second", position: "1")],
            fileURL: source)
        let corrected = try #require(
            EPUBMetadataWriter.metadataCorrectedCopy(of: source, for: book, into: scratch))

        // EPUB 2 carries a single series: the first one.
        let epub = try EPUBArchive.open(corrected)
        #expect(epub.opf.series == [BookSeries(name: "Saga", position: "3")])
    }

    @Test func unwritablePositionDoesNotForceRewrite() throws {
        let source = try MetaEPUBFixture.series(
            version: "3.0",
            metadata: """
                <meta property="belongs-to-collection" id="c1">Saga</meta>
                <meta refines="#c1" property="collection-type">series</meta>
                """)
        defer { try? FileManager.default.removeItem(at: source) }
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        // "2a" can't go into `group-position`, so writing would produce what
        // the EPUB already has.
        let book = matchingBook(series: [BookSeries(name: "Saga", position: "2a")], fileURL: source)
        #expect(EPUBMetadataWriter.metadataCorrectedCopy(of: source, for: book, into: scratch) == nil)
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

    // MARK: - Cover

    /// A 2×2 image of one colour, so different colours give different bytes.
    private func imageData(_ color: CGColor, as fileType: NSBitmapImageRep.FileType) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let rep = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        return try #require(rep.representation(using: fileType, properties: [:]))
    }

    private let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)

    /// EPUB with a JPEG cover declared both ways, plus a cover page showing it.
    private func epubWithCover(_ cover: Data) throws -> URL {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Title</dc:title>
                <dc:identifier id="id">x</dc:identifier>
                <dc:creator>Author</dc:creator>
                <dc:language>en</dc:language>
                <meta name="cover" content="cover-img"/>
              </metadata>
              <manifest>
                <item id="cover-img" href="images/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
                <item id="item0" href="ch1.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine>
                <itemref idref="item0"/>
              </spine>
            </package>
            """
        let body = """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>x</title></head><body><img src="images/cover.jpg"/></body></html>
            """
        return try MetaEPUBFixture.custom(
            opf: opf, files: ["ch1.xhtml": Data(body.utf8), "images/cover.jpg": cover])
    }

    /// A book matching the cover fixtures' metadata whose cover is `cover`,
    /// written next to the EPUB the way the library keeps it.
    private func bookWithCover(_ cover: Data?, ext: String, fileURL: URL) throws -> Book {
        var book = makeBook(title: "Title", authors: ["Author"], locale: "en", fileURL: fileURL)
        if let cover {
            let name = "cover-\(UUID().uuidString).\(ext)"
            try cover.write(to: fileURL.deletingLastPathComponent().appending(component: name))
            book.coverPath = name
        }
        return book
    }

    @Test func unchangedCoverDoesNotRewrite() throws {
        let jpeg = try imageData(red, as: .jpeg)
        let source = try epubWithCover(jpeg)
        defer { try? FileManager.default.removeItem(at: source) }
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let book = try bookWithCover(jpeg, ext: "jpg", fileURL: source)
        defer { book.coverURL.map { try? FileManager.default.removeItem(at: $0) } }

        #expect(EPUBMetadataWriter.metadataCorrectedCopy(of: source, for: book, into: scratch) == nil)
    }

    @Test func removedCoverKeepsEPUBCover() throws {
        let source = try epubWithCover(try imageData(red, as: .jpeg))
        defer { try? FileManager.default.removeItem(at: source) }
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let book = try bookWithCover(nil, ext: "jpg", fileURL: source)

        #expect(EPUBMetadataWriter.metadataCorrectedCopy(of: source, for: book, into: scratch) == nil)
    }

    @Test func changedCoverOverwritesEPUBCoverInPlace() throws {
        let source = try epubWithCover(try imageData(red, as: .jpeg))
        defer { try? FileManager.default.removeItem(at: source) }
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        // PNG over a JPEG entry: re-encoded so the declared type stays true.
        let book = try bookWithCover(try imageData(blue, as: .png), ext: "png", fileURL: source)
        defer { book.coverURL.map { try? FileManager.default.removeItem(at: $0) } }

        let corrected = try #require(
            EPUBMetadataWriter.metadataCorrectedCopy(of: source, for: book, into: scratch))
        let epub = try EPUBArchive.open(corrected)
        #expect(epub.opf.coverItem?.href == "images/cover.jpg")
        let written = try #require(epub.data(forResourceHref: "images/cover.jpg"))
        #expect(written.starts(with: [0xFF, 0xD8]))  // JPEG SOI
        let pixel = try #require(NSBitmapImageRep(data: written)?.colorAt(x: 0, y: 0))
        #expect(pixel.blueComponent > pixel.redComponent + 0.5)  // the user's blue, not the red original
    }

    @Test func coverIsAddedWhenEPUBHasNone() throws {
        let source = try MetaEPUBFixture.minimal(
            title: "Title", authors: ["Author"], language: "en",
            spineDocs: [("ch1.xhtml", "<p>Body</p>")]
        )
        defer { try? FileManager.default.removeItem(at: source) }
        let scratch = try scratchDir()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let book = try bookWithCover(try imageData(blue, as: .png), ext: "png", fileURL: source)
        defer { book.coverURL.map { try? FileManager.default.removeItem(at: $0) } }

        let corrected = try #require(
            EPUBMetadataWriter.metadataCorrectedCopy(of: source, for: book, into: scratch))
        let epub = try EPUBArchive.open(corrected)
        let item = try #require(epub.opf.coverItem)
        #expect(item.mediaType == "image/jpeg")
        #expect(item.properties == "cover-image")
        let written = try #require(epub.data(forResourceHref: item.href))
        #expect(written.starts(with: [0xFF, 0xD8]))

        // EPUB 2's declaration points at it too.
        let opf = try XMLDocument(data: try #require(epub.data(at: epub.opfPath)))
        let metaCover = try opf.nodes(forXPath: "//*[local-name()='meta' and @name='cover']/@content")
        #expect(metaCover.map(\.stringValue) == [item.id])
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

    /// Title "Title", author "Author", language "en", plus `metadata` spliced
    /// into `<metadata>`.
    static func series(version: String, metadata: String) throws -> URL {
        let opf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="\(version)" unique-identifier="id">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
                <dc:title>Title</dc:title>
                <dc:identifier id="id">x</dc:identifier>
                <dc:creator>Author</dc:creator>
                <dc:language>en</dc:language>
                \(metadata)
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
        return try custom(opf: opf, files: ["ch1.xhtml": Data(body.utf8)])
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
