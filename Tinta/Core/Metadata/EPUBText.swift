import Foundation
import ZIPFoundation

enum EPUBTextError: LocalizedError {
    case cannotOpenArchive
    case missingContainer
    case missingOPFPath
    case missingOPF
    case malformedXML

    var errorDescription: String? {
        switch self {
        case .cannotOpenArchive: "Could not open the EPUB archive."
        case .missingContainer: "EPUB is missing META-INF/container.xml."
        case .missingOPFPath: "EPUB container.xml does not point to an OPF file."
        case .missingOPF: "EPUB OPF file is missing."
        case .malformedXML: "EPUB XML is malformed."
        }
    }
}

nonisolated enum EPUBText {
    /// Extracts up to `wordLimit` words of plain text from the EPUB's spine
    /// items in reading order. Strips XHTML markup. Skips <script> and <style>.
    /// Synchronous I/O — call from off-main contexts.
    static func extract(from url: URL, wordLimit: Int = 5000) throws -> String {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw EPUBTextError.cannotOpenArchive
        }

        let containerXML = try extractData(from: archive, at: "META-INF/container.xml", whenMissing: .missingContainer)
        let opfPath = try parseOPFPath(containerXML)
        let opfXML = try extractData(from: archive, at: opfPath, whenMissing: .missingOPF)
        let spineHrefs = try parseSpineHrefs(opfXML)

        let opfDir = (opfPath as NSString).deletingLastPathComponent
        var words: [String] = []
        words.reserveCapacity(wordLimit)

        for href in spineHrefs {
            let fullPath = opfDir.isEmpty ? href : "\(opfDir)/\(href)"
            guard let entry = archive[fullPath] else { continue }

            var data = Data()
            do {
                _ = try archive.extract(entry) { data.append($0) }
            } catch {
                continue
            }

            let chunk = stripMarkup(data)
            for word in chunk.split(whereSeparator: { $0.isWhitespace }) {
                words.append(String(word))
                if words.count >= wordLimit { break }
            }
            if words.count >= wordLimit { break }
        }

        return words.joined(separator: " ")
    }
}

private nonisolated func extractData(from archive: Archive, at path: String, whenMissing: EPUBTextError) throws -> Data {
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
        throw EPUBTextError.malformedXML
    }
    let nodes = (try? doc.nodes(forXPath: "//*[local-name()='rootfile']/@full-path")) ?? []
    guard let path = nodes.first?.stringValue, !path.isEmpty else {
        throw EPUBTextError.missingOPFPath
    }
    return path
}

private nonisolated func parseSpineHrefs(_ xml: Data) throws -> [String] {
    let doc: XMLDocument
    do {
        doc = try XMLDocument(data: xml)
    } catch {
        throw EPUBTextError.malformedXML
    }

    // Build manifest: idref -> href
    let items = (try? doc.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")) ?? []
    var hrefByID: [String: String] = [:]
    for item in items {
        guard let element = item as? XMLElement,
              let id = element.attribute(forName: "id")?.stringValue,
              let href = element.attribute(forName: "href")?.stringValue
        else { continue }
        hrefByID[id] = href
    }

    // Spine in order
    let itemRefs = (try? doc.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']")) ?? []
    var hrefs: [String] = []
    for ref in itemRefs {
        guard let element = ref as? XMLElement,
              let idref = element.attribute(forName: "idref")?.stringValue,
              let href = hrefByID[idref]
        else { continue }
        hrefs.append(href)
    }
    return hrefs
}

private nonisolated func stripMarkup(_ data: Data) -> String {
    // EPUB spine items are XHTML — XMLDocument with default options should parse them.
    // Fall back to HTML tidy mode for files with malformed XHTML.
    let doc: XMLDocument? = {
        if let strict = try? XMLDocument(data: data, options: []) {
            return strict
        }
        return try? XMLDocument(data: data, options: .documentTidyHTML)
    }()
    guard let doc, let root = doc.rootElement() else { return "" }
    return collectText(from: root).joined(separator: " ")
}

private nonisolated func collectText(from node: XMLNode) -> [String] {
    if node.kind == .text {
        if let s = node.stringValue, !s.isEmpty { return [s] }
        return []
    }
    if let element = node as? XMLElement,
       let name = element.localName,
       name == "script" || name == "style" {
        return []
    }
    return (node.children ?? []).flatMap { collectText(from: $0) }
}
