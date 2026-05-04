import Foundation
import Testing
import ZIPFoundation

@testable import Tomo

@Suite("EPUBSource")
struct EPUBSourceTests {

  @Test func readsTitleAuthorLanguageFromOPF() throws {
    let url = try EPUBFixture.minimal(
      title: "Frankenstein",
      authors: ["Mary Shelley"],
      language: "en-GB",
      spineDocs: [("ch1.xhtml", "<p>Hello</p>")]
    )
    defer { try? FileManager.default.removeItem(at: url) }

    let manifest = try EPUBSource.read(from: url)
    #expect(manifest.title == "Frankenstein")
    #expect(manifest.authors == ["Mary Shelley"])
    #expect(manifest.language == "en-GB")
  }

  @Test func languageDefaultsToUndWhenAbsent() throws {
    let url = try EPUBFixture.minimal(
      title: "Untitled",
      authors: [],
      language: nil,
      spineDocs: [("ch1.xhtml", "<p>Body</p>")]
    )
    defer { try? FileManager.default.removeItem(at: url) }

    let manifest = try EPUBSource.read(from: url)
    #expect(manifest.language == "und")
  }

  @Test func extractsBodyInnerHTMLPerSpineItem() throws {
    let url = try EPUBFixture.minimal(
      title: "T",
      authors: [],
      language: "en",
      spineDocs: [
        ("ch1.xhtml", "<h1>Chapter 1</h1><p>Para one.</p>"),
        ("ch2.xhtml", "<p>Chapter two body.</p>"),
      ]
    )
    defer { try? FileManager.default.removeItem(at: url) }

    let manifest = try EPUBSource.read(from: url)
    #expect(manifest.chunks.count == 2)
    // Each chunk must contain the body inner content. Whitespace
    // and namespace serialisation may vary; check for substrings.
    #expect(manifest.chunks[0].contains("Chapter 1"))
    #expect(manifest.chunks[0].contains("Para one."))
    #expect(manifest.chunks[1].contains("Chapter two body."))
    // No <html>/<head>/<body> wrappers should be present.
    #expect(!manifest.chunks[0].contains("<body"))
    #expect(!manifest.chunks[0].contains("</body>"))
    #expect(!manifest.chunks[0].contains("<html"))
  }

  @Test func preservesSpineReadingOrder() throws {
    // Manifest declares items in arbitrary order; spine declares
    // reading order. Result must follow spine.
    let url = try EPUBFixture.custom(
      opf: """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Order Test</dc:title>
            <dc:identifier id="id">x</dc:identifier>
            <dc:language>en</dc:language>
          </metadata>
          <manifest>
            <item id="b" href="b.xhtml" media-type="application/xhtml+xml"/>
            <item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>
            <item id="c" href="c.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="a"/>
            <itemref idref="b"/>
            <itemref idref="c"/>
          </spine>
        </package>
        """,
      files: [
        "a.xhtml": Data(xhtmlBody("<p>FIRST</p>").utf8),
        "b.xhtml": Data(xhtmlBody("<p>SECOND</p>").utf8),
        "c.xhtml": Data(xhtmlBody("<p>THIRD</p>").utf8),
      ])
    defer { try? FileManager.default.removeItem(at: url) }

    let manifest = try EPUBSource.read(from: url)
    #expect(manifest.chunks.count == 3)
    #expect(manifest.chunks[0].contains("FIRST"))
    #expect(manifest.chunks[1].contains("SECOND"))
    #expect(manifest.chunks[2].contains("THIRD"))
  }

  @Test func multibyteContentRoundtripsAsBytes() throws {
    // Portuguese accented text. The body inner HTML must preserve
    // the actual UTF-8 bytes — Swift's XMLDocument has been known
    // to mangle these on serialisation.
    let url = try EPUBFixture.minimal(
      title: "Coração",
      authors: ["José"],
      language: "pt-PT",
      spineDocs: [("ch1.xhtml", "<p>O coração é um músculo.</p>")]
    )
    defer { try? FileManager.default.removeItem(at: url) }

    let manifest = try EPUBSource.read(from: url)
    #expect(manifest.title == "Coração")
    #expect(manifest.authors == ["José"])
    #expect(manifest.chunks[0].contains("coração"))
    #expect(manifest.chunks[0].contains("músculo"))
  }

  @Test func missingTitleThrows() throws {
    let url = try EPUBFixture.custom(
      opf: """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="id">x</dc:identifier>
          </metadata>
          <manifest></manifest>
          <spine></spine>
        </package>
        """, files: [:])
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(throws: EPUBArchiveError.self) {
      _ = try EPUBSource.read(from: url)
    }
  }

  @Test func nonEpubArchiveThrows() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(UUID().uuidString).epub")
    try Data("not a zip".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(throws: EPUBArchiveError.self) {
      _ = try EPUBSource.read(from: url)
    }
  }
}

// MARK: - Fixture builder

/// Builds minimal EPUB ZIP files in the temp directory for tests.
/// The structure follows EPUB 3 with a single OPF at `OEBPS/content.opf`.
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

    var files: [String: Data] = [:]
    for doc in spineDocs {
      files[doc.href] = Data(xhtmlBody(doc.body).utf8)
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

    for (relPath, data) in files {
      try addEntry(archive: archive, path: "OEBPS/\(relPath)", data: data)
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

private func xhtmlBody(_ inner: String) -> String {
  """
  <?xml version="1.0" encoding="UTF-8"?>
  <html xmlns="http://www.w3.org/1999/xhtml">
    <head><title>x</title></head>
    <body>\(inner)</body>
  </html>
  """
}
