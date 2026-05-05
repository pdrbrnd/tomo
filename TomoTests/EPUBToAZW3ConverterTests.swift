import AZW3
import Foundation
import Testing
import ZIPFoundation

@testable import Tomo

@Suite("EPUBToAZW3Converter end-to-end")
struct EPUBToAZW3ConverterTests {

    @Test func convertsAMinimalEPUBToAZW3OnDisk() async throws {
        let epub = try EPUBFixture.minimal(
            title: "Frankenstein",
            authors: ["Mary Shelley"],
            language: "en-GB",
            spineDocs: [
                ("ch1.xhtml", "<h1>Letter 1</h1><p>To Mrs Saville, England.</p>")
            ]
        )
        defer { try? FileManager.default.removeItem(at: epub) }

        let scratch = FileManager.default.temporaryDirectory
            .appending(component: "azw3test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let output = try await EPUBToAZW3Converter().convert(source: epub, into: scratch)

        // File exists and has the expected stem + extension.
        #expect(FileManager.default.fileExists(atPath: output.path(percentEncoded: false)))
        #expect(output.lastPathComponent == "\(epub.deletingPathExtension().lastPathComponent).azw3")

        // File starts with the right PalmDB magic.
        let bytes = Array(try Data(contentsOf: output))
        #expect(Array(bytes[60..<64]) == [0x42, 0x4F, 0x4F, 0x4B])  // "BOOK"
        #expect(Array(bytes[64..<68]) == [0x4D, 0x4F, 0x42, 0x49])  // "MOBI"
        // Ends with EOF.
        #expect(Array(bytes.suffix(4)) == [0xE9, 0x8E, 0x0D, 0x0A])
    }

    @Test func registryContainsEPUBToAZW3() {
        // Phase 1 ships exactly one converter. Confirm the registry
        // wiring so dropping an EPUB on the Kindle device card finds
        // the converter rather than falling through to "no converter."
        let converter = ConversionRegistry.default.converter(from: .epub, to: .azw3)
        #expect(converter != nil)
    }

    @Test func registryReturnsNilForUnknownPair() {
        // Sanity: asking for a conversion we don't support returns nil.
        let converter = ConversionRegistry.default.converter(from: .azw3, to: .epub)
        #expect(converter == nil)
    }
}

// MARK: - Fixture builder (duplicated from EPUBSourceTests because
// Swift Testing doesn't have a clean cross-suite shared-fixture story
// yet; resolve when the test target gets a Helpers/ folder).

private enum EPUBFixture {

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
        let manifestItems = spineDocs.enumerated()
            .map { (i, doc) in
                "<item id=\"item\(i)\" href=\"\(doc.href)\" media-type=\"application/xhtml+xml\"/>"
            }
            .joined(separator: "\n    ")
        let spineRefs = spineDocs.indices
            .map { "<itemref idref=\"item\($0)\"/>" }
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
                \(manifestItems)
              </manifest>
              <spine>
                \(spineRefs)
              </spine>
            </package>
            """

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).epub")
        let archive = try Archive(url: url, accessMode: .create)

        let mimetype = Data("application/epub+zip".utf8)
        try archive.addEntry(
            with: "mimetype",
            type: .file,
            uncompressedSize: Int64(mimetype.count),
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

        for doc in spineDocs {
            let xhtml = """
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml">
                  <head><title>x</title></head>
                  <body>\(doc.body)</body>
                </html>
                """
            try addEntry(archive: archive, path: "OEBPS/\(doc.href)", data: Data(xhtml.utf8))
        }

        return url
    }

    private static func addEntry(archive: Archive, path: String, data: Data) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate,
            provider: { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        )
    }
}
