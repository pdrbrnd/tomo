import Foundation
import ZIPFoundation

/// Reads an EPUB and produces a `BookManifest` ready for the AZW3
/// writer. Phase 1 minimum: title, authors, language, and the inner
/// HTML body content of each spine item in reading order. No cover,
/// no TOC, no CSS — those layer on in Phase 2.
///
/// Sits *outside* the `AZW3/` directory because EPUB knowledge belongs
/// to Acervo, not the writer. The writer accepts a plain `BookManifest`
/// and doesn't know EPUB exists. See `AZW3/README.md` for the
/// isolation contract.
nonisolated enum EPUBSource {

    static func read(from url: URL) throws -> BookManifest {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw EPUBSourceError.cannotOpenArchive
        }

        let containerXML = try extract(
            from: archive,
            at: "META-INF/container.xml",
            whenMissing: .missingContainer)
        let opfPath = try parseOPFPath(containerXML)

        let opfXML = try extract(
            from: archive,
            at: opfPath,
            whenMissing: .missingOPF)
        let parsed = try parseOPF(opfXML)

        let opfDir = (opfPath as NSString).deletingLastPathComponent
        var chunks: [String] = []
        chunks.reserveCapacity(parsed.spineHrefs.count)
        for href in parsed.spineHrefs {
            let path = opfDir.isEmpty ? href : "\(opfDir)/\(href)"
            guard let entry = archive[path] else { continue }
            var data = Data()
            do {
                _ = try archive.extract(entry) { data.append($0) }
            } catch {
                continue
            }
            if let inner = bodyInnerHTML(from: data) {
                chunks.append(inner)
            }
        }

        return BookManifest(
            title: parsed.title,
            authors: parsed.authors,
            language: parsed.language ?? "und",
            chunks: chunks
        )
    }
}

enum EPUBSourceError: LocalizedError {
    case cannotOpenArchive
    case missingContainer
    case missingOPFPath
    case missingOPF
    case missingTitle
    case malformedXML

    var errorDescription: String? {
        switch self {
        case .cannotOpenArchive: "Could not open the EPUB archive."
        case .missingContainer: "EPUB is missing META-INF/container.xml."
        case .missingOPFPath: "EPUB container.xml does not point to an OPF file."
        case .missingOPF: "EPUB OPF file is missing."
        case .missingTitle: "EPUB does not declare a title."
        case .malformedXML: "EPUB metadata XML is malformed."
        }
    }
}

// MARK: - Internals

private nonisolated func extract(
    from archive: Archive, at path: String, whenMissing: EPUBSourceError
) throws -> Data {
    guard let entry = archive[path] else { throw whenMissing }
    var data = Data()
    _ = try archive.extract(entry) { data.append($0) }
    return data
}

private nonisolated func parseOPFPath(_ xml: Data) throws -> String {
    let doc: XMLDocument
    do {
        doc = try XMLDocument(data: xml)
    } catch {
        throw EPUBSourceError.malformedXML
    }
    let nodes = (try? doc.nodes(forXPath: "//*[local-name()='rootfile']/@full-path")) ?? []
    guard let path = nodes.first?.stringValue, !path.isEmpty else {
        throw EPUBSourceError.missingOPFPath
    }
    return path
}

private struct ParsedOPF {
    let title: String
    let authors: [String]
    let language: String?
    let spineHrefs: [String]
}

private nonisolated func parseOPF(_ xml: Data) throws -> ParsedOPF {
    let doc: XMLDocument
    do {
        doc = try XMLDocument(data: xml)
    } catch {
        throw EPUBSourceError.malformedXML
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

    guard let title = first("//*[local-name()='title']"), !title.isEmpty else {
        throw EPUBSourceError.missingTitle
    }
    let authors = all("//*[local-name()='creator']")
    let language = first("//*[local-name()='language']")

    // Manifest map (idref -> href) and spine in order.
    let items = (try? doc.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")) ?? []
    var hrefByID: [String: String] = [:]
    for item in items {
        guard let element = item as? XMLElement,
              let id = element.attribute(forName: "id")?.stringValue,
              let href = element.attribute(forName: "href")?.stringValue
        else { continue }
        hrefByID[id] = href
    }

    let itemRefs = (try? doc.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']")) ?? []
    var spineHrefs: [String] = []
    for ref in itemRefs {
        guard let element = ref as? XMLElement,
              let idref = element.attribute(forName: "idref")?.stringValue,
              let href = hrefByID[idref]
        else { continue }
        spineHrefs.append(href)
    }

    return ParsedOPF(
        title: title,
        authors: authors,
        language: language,
        spineHrefs: spineHrefs
    )
}

/// Extracts the inner HTML of the `<body>` element from an XHTML
/// document. Returns `nil` for unparseable or body-less documents.
/// Falls back to HTML tidy mode for files with malformed XHTML —
/// real EPUBs in the wild are rarely strict.
private nonisolated func bodyInnerHTML(from data: Data) -> String? {
    let doc: XMLDocument? = {
        if let strict = try? XMLDocument(data: data, options: []) {
            return strict
        }
        return try? XMLDocument(data: data, options: .documentTidyHTML)
    }()
    guard let doc, let root = doc.rootElement() else { return nil }
    let bodies = (try? doc.nodes(forXPath: "//*[local-name()='body']")) ?? []
    let body = (bodies.first as? XMLElement) ?? findBody(in: root)
    guard let body else { return nil }

    return (body.children ?? [])
        .map { $0.xmlString(options: [.nodePreserveCDATA]) }
        .joined()
}

/// Fallback search when XPath fails (some malformed inputs strip the
/// XHTML namespace and the document-tidy XPath misses the body).
private nonisolated func findBody(in node: XMLNode) -> XMLElement? {
    if let element = node as? XMLElement, element.localName == "body" {
        return element
    }
    for child in node.children ?? [] {
        if let found = findBody(in: child) {
            return found
        }
    }
    return nil
}
