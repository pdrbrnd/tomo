import Foundation
import ZIPFoundation

/// Single-pass EPUB reader. Opens the archive, resolves the OPF, parses it,
/// and exposes the parsed data plus convenience accessors for resource files.
///
/// Consumers (`EPUBMetadata`, `EPUBText`, `EPUBSource`) construct one of
/// these per EPUB instead of opening the archive themselves — opening,
/// extracting `META-INF/container.xml`, and parsing the OPF used to happen
/// three times per EPUB on import.
nonisolated struct EPUBArchive {
    let archive: Archive
    let opfPath: String
    let opfDir: String
    let opf: ParsedOPF

    static func open(_ url: URL) throws -> EPUBArchive {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw EPUBArchiveError.cannotOpenArchive
        }
        // DRM detection — `META-INF/encryption.xml` exists in any EPUB
        // with encrypted resources. We refuse rather than emit garbage
        // AZW3 from undecryptable bodies.
        if archive["META-INF/encryption.xml"] != nil {
            throw EPUBArchiveError.drmProtected
        }
        let containerXML = try archiveData(in: archive, at: "META-INF/container.xml", whenMissing: .missingContainer)
        let opfPath = try parseOPFPath(containerXML)
        let opfXML = try archiveData(in: archive, at: opfPath, whenMissing: .missingOPF)
        let opf = try parseOPF(opfXML)
        let opfDir = (opfPath as NSString).deletingLastPathComponent
        return EPUBArchive(archive: archive, opfPath: opfPath, opfDir: opfDir, opf: opf)
    }

    /// Looks up a resource referenced from the OPF's `manifest` (or any
    /// path relative to the OPF directory). Returns nil if missing or
    /// extraction fails.
    func data(forResourceHref href: String) -> Data? {
        let path = opfDir.isEmpty ? href : "\(opfDir)/\(href)"
        return data(at: path)
    }

    /// Looks up a raw archive entry by its full ZIP path. Use for non-OPF
    /// paths like `META-INF/encryption.xml`.
    func data(at path: String) -> Data? {
        guard let entry = archive[path] else { return nil }
        var out = Data()
        do {
            _ = try archive.extract(entry) { out.append($0) }
        } catch {
            return nil
        }
        return out
    }

    /// Resolves a relative href to an archive-absolute, normalised path.
    /// Strips `#fragment`s and percent-decodes. `baseDir` is itself
    /// archive-absolute (the directory the href is relative to).
    static func resolvePath(_ href: String, baseDir: String) -> String {
        let withoutFragment: String = {
            if let i = href.firstIndex(of: "#") {
                return String(href[..<i])
            }
            return href
        }()
        let decoded = withoutFragment.removingPercentEncoding ?? withoutFragment
        let combined = baseDir.isEmpty ? decoded : "\(baseDir)/\(decoded)"
        var stack: [Substring] = []
        for part in combined.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !stack.isEmpty { stack.removeLast() }
                continue
            }
            stack.append(part)
        }
        return stack.joined(separator: "/")
    }
}

struct ParsedOPF: Sendable {
    /// `<dc:title>`. nil if absent — consumers that require a title should
    /// throw `EPUBArchiveError.missingTitle`.
    let title: String?
    let authors: [String]
    /// BCP 47 `<dc:language>`, or nil if absent.
    let language: String?
    /// Raw `<dc:date>` string. ISO-8601-ish but real-world EPUBs are messy.
    let date: String?
    /// `<dc:identifier>`. Prefers the one matching `<package unique-identifier>`.
    let identifier: String?
    let manifest: [ManifestItem]
    let spineHrefs: [String]
    /// Manifest item for the cover image (EPUB 2 or 3), if declared.
    let coverItem: ManifestItem?
    /// EPUB 3 nav document.
    let navItem: ManifestItem?
    /// EPUB 2 NCX document.
    let ncxItem: ManifestItem?
}

struct ManifestItem: Sendable {
    let id: String
    let href: String
    let mediaType: String
    let properties: String?
}

enum EPUBArchiveError: LocalizedError {
    case cannotOpenArchive
    case missingContainer
    case missingOPFPath
    case missingOPF
    case missingTitle
    case malformedXML
    case drmProtected
    case noReadableContent

    var errorDescription: String? {
        switch self {
        case .cannotOpenArchive: "Could not open the EPUB archive."
        case .missingContainer: "EPUB is missing META-INF/container.xml."
        case .missingOPFPath: "EPUB container.xml does not point to an OPF file."
        case .missingOPF: "EPUB OPF file is missing."
        case .missingTitle: "EPUB does not declare a title."
        case .malformedXML: "EPUB metadata XML is malformed."
        case .drmProtected: "This EPUB is protected by DRM and can't be converted."
        case .noReadableContent: "This EPUB has no readable content."
        }
    }
}

// MARK: - Internals

private nonisolated func archiveData(
    in archive: Archive, at path: String, whenMissing: EPUBArchiveError
) throws -> Data {
    guard let entry = archive[path] else { throw whenMissing }
    var out = Data()
    _ = try archive.extract(entry) { out.append($0) }
    return out
}

private nonisolated func parseOPFPath(_ xml: Data) throws -> String {
    let doc: XMLDocument
    do {
        doc = try XMLDocument(data: xml)
    } catch {
        throw EPUBArchiveError.malformedXML
    }
    let nodes = (try? doc.nodes(forXPath: "//*[local-name()='rootfile']/@full-path")) ?? []
    guard let path = nodes.first?.stringValue, !path.isEmpty else {
        throw EPUBArchiveError.missingOPFPath
    }
    return path
}

private nonisolated func parseOPF(_ xml: Data) throws -> ParsedOPF {
    let doc: XMLDocument
    do {
        doc = try XMLDocument(data: xml)
    } catch {
        throw EPUBArchiveError.malformedXML
    }

    func first(_ xpath: String) -> String? {
        let nodes = (try? doc.nodes(forXPath: xpath)) ?? []
        return nodes.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func all(_ xpath: String) -> [String] {
        let nodes = (try? doc.nodes(forXPath: xpath)) ?? []
        return nodes
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    let title = first("//*[local-name()='title']").flatMap { $0.isEmpty ? nil : $0 }
    let authors = all("//*[local-name()='creator']")
    let language = first("//*[local-name()='language']")
    let date = first("//*[local-name()='date']")

    // <package unique-identifier="ID"> + <dc:identifier id="ID"> wins.
    let uniqueIDAttr = first("//*[local-name()='package']/@unique-identifier")
    let identifier: String? = {
        if let id = uniqueIDAttr, !id.isEmpty,
           let value = first("//*[local-name()='identifier' and @id='\(id)']") {
            return value
        }
        return first("//*[local-name()='identifier']")
    }()

    // Manifest in document order, with id/href/media-type/properties.
    let itemNodes = (try? doc.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")) ?? []
    var manifest: [ManifestItem] = []
    var hrefByID: [String: String] = [:]
    for node in itemNodes {
        guard let element = node as? XMLElement,
              let id = element.attribute(forName: "id")?.stringValue,
              let href = element.attribute(forName: "href")?.stringValue
        else { continue }
        let mediaType = element.attribute(forName: "media-type")?.stringValue ?? ""
        let properties = element.attribute(forName: "properties")?.stringValue
        manifest.append(ManifestItem(id: id, href: href, mediaType: mediaType, properties: properties))
        hrefByID[id] = href
    }

    // Spine in reading order.
    let itemRefs = (try? doc.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']")) ?? []
    var spineHrefs: [String] = []
    for ref in itemRefs {
        guard let element = ref as? XMLElement,
              let idref = element.attribute(forName: "idref")?.stringValue,
              let href = hrefByID[idref]
        else { continue }
        spineHrefs.append(href)
    }

    func itemByHref(_ href: String) -> ManifestItem? { manifest.first { $0.href == href } }
    func itemByID(_ id: String) -> ManifestItem? { manifest.first { $0.id == id } }

    // Cover: EPUB 3 properties="cover-image" first, then EPUB 2 <meta name="cover" content="ID">.
    let coverItem: ManifestItem? = {
        if let href = first("//*[local-name()='item' and contains(@properties, 'cover-image')]/@href"),
           !href.isEmpty,
           let item = itemByHref(href) {
            return item
        }
        guard let id = first("//*[local-name()='meta' and @name='cover']/@content"), !id.isEmpty else {
            return nil
        }
        return itemByID(id)
    }()

    // Nav (EPUB 3): manifest item with properties containing "nav".
    let navItem: ManifestItem? = {
        guard let href = first("//*[local-name()='item' and contains(@properties, 'nav')]/@href"),
              !href.isEmpty else { return nil }
        return itemByHref(href)
    }()

    // NCX (EPUB 2): spine has @toc pointing to a manifest item id.
    let ncxItem: ManifestItem? = {
        guard let ncxID = first("//*[local-name()='spine']/@toc"), !ncxID.isEmpty else {
            return nil
        }
        return itemByID(ncxID)
    }()

    return ParsedOPF(
        title: title,
        authors: authors,
        language: language,
        date: date,
        identifier: identifier,
        manifest: manifest,
        spineHrefs: spineHrefs,
        coverItem: coverItem,
        navItem: navItem,
        ncxItem: ncxItem
    )
}
