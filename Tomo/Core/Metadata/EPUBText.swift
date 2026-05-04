import Foundation

nonisolated enum EPUBText {
    /// Extracts up to `wordLimit` words of plain text from the EPUB's spine
    /// items in reading order. Strips XHTML markup. Skips `<script>` and
    /// `<style>`. Synchronous I/O — call from off-main contexts.
    static func extract(from url: URL, wordLimit: Int = 5000) throws -> String {
        let epub = try EPUBArchive.open(url)
        var words: [String] = []
        words.reserveCapacity(wordLimit)
        for href in epub.opf.spineHrefs {
            guard let data = epub.data(forResourceHref: href) else { continue }
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

private nonisolated func stripMarkup(_ data: Data) -> String {
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
