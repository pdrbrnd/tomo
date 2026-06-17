import Foundation
import Testing
import ZIPFoundation

@testable import Tomo

/// `META-INF/encryption.xml` is present both in DRM-protected EPUBs and in
/// DRM-free books that only obfuscate embedded fonts. `EPUBArchive.open` must
/// import the latter and refuse the former — see `isDRMEncryption`.
@MainActor
struct EPUBEncryptionTests {
    @Test func importsBookWithObfuscatedFonts() throws {
        let url = try makeEPUB(
            encryptionXML: encryption(algorithms: ["http://www.idpf.org/2008/embedding"]))
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try EPUBMetadata.read(from: url)
        #expect(metadata.title == "Obfuscated Fonts")
    }

    @Test func importsBookWithAdobeObfuscatedFonts() throws {
        let url = try makeEPUB(
            encryptionXML: encryption(algorithms: ["http://ns.adobe.com/pdf/enc#RC"]))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: Never.self) { try EPUBMetadata.read(from: url) }
    }

    @Test func refusesRealDRM() throws {
        let url = try makeEPUB(
            encryptionXML: encryption(algorithms: ["http://www.w3.org/2001/04/xmlenc#aes128-cbc"]))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: EPUBArchiveError.drmProtected) { try EPUBMetadata.read(from: url) }
    }

    /// Mixed: one obfuscated font + one real-DRM'd resource → DRM wins.
    @Test func refusesWhenAnyResourceUsesRealEncryption() throws {
        let url = try makeEPUB(
            encryptionXML: encryption(algorithms: [
                "http://www.idpf.org/2008/embedding",
                "http://www.w3.org/2001/04/xmlenc#aes128-cbc",
            ]))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: EPUBArchiveError.drmProtected) { try EPUBMetadata.read(from: url) }
    }

    /// Unparseable / empty encryption.xml is ambiguous — refuse conservatively.
    @Test func refusesUnreadableEncryptionFile() throws {
        let url = try makeEPUB(encryptionXML: Data("not xml at all".utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: EPUBArchiveError.drmProtected) { try EPUBMetadata.read(from: url) }
    }

    @Test func importsBookWithNoEncryptionFile() throws {
        let url = try makeEPUB(encryptionXML: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: Never.self) { try EPUBMetadata.read(from: url) }
    }

    // MARK: - Fixtures

    private func encryption(algorithms: [String]) -> Data {
        let entries = algorithms.enumerated().map { index, algorithm in
            """
              <enc:EncryptedData>
                <enc:EncryptionMethod Algorithm="\(algorithm)"/>
                <enc:CipherData><enc:CipherReference URI="OEBPS/res\(index).bin"/></enc:CipherData>
              </enc:EncryptedData>
            """
        }.joined(separator: "\n")
        return Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                        xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
            \(entries)
            </encryption>
            """.utf8)
    }

    private func makeEPUB(encryptionXML: Data?) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).epub")
        let archive = try Archive(url: url, accessMode: .create)

        let mimetype = Data("application/epub+zip".utf8)
        try archive.addEntry(
            with: "mimetype", type: .file, uncompressedSize: Int64(mimetype.count),
            compressionMethod: .none,
            provider: { position, size in
                mimetype.subdata(in: Int(position)..<Int(position) + size)
            })

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

        let opf = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Obfuscated Fonts</dc:title>
                <dc:creator>A. Author</dc:creator>
                <dc:language>en</dc:language>
                <dc:identifier id="bookid">urn:uuid:test</dc:identifier>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
              </manifest>
              <spine><itemref idref="nav"/></spine>
            </package>
            """.utf8)
        try addEntry(archive: archive, path: "OEBPS/content.opf", data: opf)

        if let encryptionXML {
            try addEntry(archive: archive, path: "META-INF/encryption.xml", data: encryptionXML)
        }
        return url
    }

    private func addEntry(archive: Archive, path: String, data: Data) throws {
        try archive.addEntry(
            with: path, type: .file, uncompressedSize: Int64(data.count),
            compressionMethod: .deflate,
            provider: { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            })
    }
}
