import Foundation

/// One TOC entry parsed out of an EPUB's navigation document. The
/// `resourcePath` field is an archive-absolute, normalized path that
/// can be matched against `EPUBArchive.opfDir + "/" + spineHref`.
nonisolated struct ParsedTOCEntry: Sendable {
    let title: String
    /// Archive-absolute path to the spine document. Fragments (`#anchor`)
    /// are stripped — anchor-level granularity is not supported in v1.
    let resourcePath: String
}

nonisolated enum EPUBNavigation {
    /// Tries EPUB 3 nav.xhtml first, falls back to EPUB 2 toc.ncx.
    /// Returns an empty array if neither is found or both fail to parse.
    static func parse(in epub: EPUBArchive) -> [ParsedTOCEntry] {
        if let nav = epub.opf.navItem,
            let entries = parseNav(nav.href, in: epub),
            !entries.isEmpty
        {
            return entries
        }
        if let ncx = epub.opf.ncxItem,
            let entries = parseNCX(ncx.href, in: epub),
            !entries.isEmpty
        {
            return entries
        }
        return []
    }
}

private nonisolated func parseNav(_ navHref: String, in epub: EPUBArchive) -> [ParsedTOCEntry]? {
    guard let data = epub.data(forResourceHref: navHref) else { return nil }
    guard let doc = parseXHTMLOrTidy(data) else { return nil }

    // Prefer <nav epub:type="toc">; some EPUBs omit the type attribute,
    // so fall back to the first <nav> in the document.
    let typedXPath = "//*[local-name()='nav' and @*[local-name()='type']='toc']"
    let untypedXPath = "//*[local-name()='nav']"
    let typed = (try? doc.nodes(forXPath: typedXPath)) ?? []
    let untyped = (try? doc.nodes(forXPath: untypedXPath)) ?? []
    guard let nav = (typed.first ?? untyped.first) as? XMLElement else { return nil }

    let baseDir = navParentDir(opfDir: epub.opfDir, navHref: navHref)
    let anchors = (try? nav.nodes(forXPath: ".//*[local-name()='a']")) ?? []
    var entries: [ParsedTOCEntry] = []
    for node in anchors {
        guard let element = node as? XMLElement,
            let href = element.attribute(forName: "href")?.stringValue,
            !href.isEmpty
        else { continue }
        let title = (element.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { continue }
        entries.append(
            ParsedTOCEntry(
                title: title,
                resourcePath: EPUBArchive.resolvePath(href, baseDir: baseDir)
            ))
    }
    return entries
}

private nonisolated func parseNCX(_ ncxHref: String, in epub: EPUBArchive) -> [ParsedTOCEntry]? {
    guard let data = epub.data(forResourceHref: ncxHref) else { return nil }
    guard let doc = try? XMLDocument(data: data) else { return nil }

    let baseDir = navParentDir(opfDir: epub.opfDir, navHref: ncxHref)
    let navPoints = (try? doc.nodes(forXPath: "//*[local-name()='navMap']//*[local-name()='navPoint']")) ?? []
    var entries: [ParsedTOCEntry] = []
    for node in navPoints {
        guard let element = node as? XMLElement else { continue }
        // Direct child navLabel/text, not descendants — nested navPoints
        // would otherwise inherit titles from their parent.
        let labelNodes = (try? element.nodes(forXPath: "./*[local-name()='navLabel']/*[local-name()='text']")) ?? []
        let title = (labelNodes.first?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { continue }

        let srcNodes = (try? element.nodes(forXPath: "./*[local-name()='content']/@src")) ?? []
        guard let href = srcNodes.first?.stringValue, !href.isEmpty else { continue }
        entries.append(
            ParsedTOCEntry(
                title: title,
                resourcePath: EPUBArchive.resolvePath(href, baseDir: baseDir)
            ))
    }
    return entries
}

/// Archive-absolute parent directory of the nav file. `opfDir` is the
/// parent of the OPF; `navHref` is OPF-relative.
private nonisolated func navParentDir(opfDir: String, navHref: String) -> String {
    EPUBArchive.resolvePath(
        (navHref as NSString).deletingLastPathComponent,
        baseDir: opfDir
    )
}
