import Foundation

/// Custom URL scheme the reader serves the book through. Lives in Core (no
/// WebKit) so both the content builder and the WebKit loader agree on URL
/// shape without a layering violation.
nonisolated enum EPUBReaderScheme {
    static let scheme = "tomo-epub"
    static let host = "book"
    /// Path of the single synthetic document that holds the whole book.
    static let documentPath = "__reader__"

    static var documentURL: URL? { url(forArchivePath: documentPath) }

    /// The in-webview URL for an archive-absolute resource path.
    static func url(forArchivePath path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + path
        return components.url
    }

    /// The archive-absolute path encoded in a `tomo-epub://` URL.
    static func archivePath(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var path = components.path
        if path.hasPrefix("/") { path.removeFirst() }
        return path.removingPercentEncoding ?? path
    }
}

/// One entry in the reader's table of contents, pointing at an in-document
/// anchor (`ch-<spineIndex>`) the whole-book scroll can jump to.
nonisolated struct ReaderTOCItem: Sendable, Identifiable {
    let id = UUID()
    let title: String
    let anchor: String
}

/// The whole book rendered as a single, self-styled HTML document for
/// continuous-scroll reading. The book's own CSS is dropped entirely and the
/// content is reduced to semantics (headings, paragraphs, lists, images,
/// quotes…) so the reader's own typography governs — no leaked book styles,
/// no black-on-black, no neon links. Images stay, resolved to `tomo-epub://`
/// URLs the loader serves lazily.
nonisolated struct EPUBReaderContent: Sendable {
    let html: String
    let toc: [ReaderTOCItem]

    static func build(fileURL: URL) throws -> EPUBReaderContent {
        let epub = try EPUBArchive.open(fileURL)
        guard !epub.opf.spineHrefs.isEmpty else {
            throw EPUBArchiveError.noReadableContent
        }

        var indexByPath: [String: Int] = [:]
        var sections: [String] = []
        for (index, href) in epub.opf.spineHrefs.enumerated() {
            let archivePath = EPUBArchive.resolvePath(href, baseDir: epub.opfDir)
            if indexByPath[archivePath] == nil { indexByPath[archivePath] = index }
            guard let data = epub.data(forResourceHref: href),
                let body = sanitizedBody(
                    data, spineDir: (archivePath as NSString).deletingLastPathComponent,
                    spineIndexByPath: spineIndexResolver(epub: epub))
            else { continue }
            sections.append("<section class=\"chapter\" id=\"ch-\(index)\">\(body)</section>")
        }
        guard !sections.isEmpty else {
            throw EPUBArchiveError.noReadableContent
        }

        let toc: [ReaderTOCItem] = EPUBNavigation.parse(in: epub).compactMap { entry in
            guard let index = indexByPath[entry.resourcePath] else { return nil }
            return ReaderTOCItem(title: entry.title, anchor: "ch-\(index)")
        }

        let document =
            "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
            + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            + "<style>\(readerCSS)</style></head>"
            + "<body><div class=\"reader\">\(sections.joined())</div></body></html>"

        return EPUBReaderContent(html: document, toc: toc)
    }

    /// Closure that maps an archive-absolute path to its spine index, captured
    /// once so anchor rewriting doesn't re-walk the spine per link.
    private static func spineIndexResolver(epub: EPUBArchive) -> [String: Int] {
        var map: [String: Int] = [:]
        for (index, href) in epub.opf.spineHrefs.enumerated() {
            let path = EPUBArchive.resolvePath(href, baseDir: epub.opfDir)
            if map[path] == nil { map[path] = index }
        }
        return map
    }
}

// MARK: - Sanitisation

/// Presentational attributes stripped from every element so the reader's
/// stylesheet — not the book's — governs colour, font, and layout.
private nonisolated let presentationalAttributes: [String] = [
    "style", "class", "bgcolor", "color", "align", "valign", "width", "height",
    "face", "size", "link", "vlink", "alink", "text", "border", "cellpadding",
    "cellspacing", "hspace", "vspace", "background",
]

/// Returns the sanitised inner HTML of an XHTML spine document's `<body>`:
/// presentational attributes removed, `<script>`/`<style>`/`<link>` dropped,
/// image and anchor URLs rewritten for whole-book scroll. Returns nil if the
/// document has no body or no content.
private nonisolated func sanitizedBody(
    _ data: Data, spineDir: String, spineIndexByPath: [String: Int]
) -> String? {
    guard let doc = parseXHTMLOrTidy(data, options: .nodePreserveWhitespace),
        let body = (try? doc.nodes(forXPath: "//*[local-name()='body']"))?.first as? XMLElement
    else { return nil }

    sanitize(body, spineDir: spineDir, spineIndexByPath: spineIndexByPath)

    let inner = (body.children ?? [])
        .map { $0.xmlString(options: [.nodePreserveCDATA]) }
        .joined()
    // Skip whitespace-only spine docs (blank placeholder pages). Preserving
    // whitespace keeps their stray spaces, which would otherwise render as an
    // empty chapter — a 6rem gap and a separator rule between real chapters.
    return inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : inner
}

private nonisolated func sanitize(
    _ element: XMLElement, spineDir: String, spineIndexByPath: [String: Int]
) {
    for name in presentationalAttributes {
        element.removeAttribute(forName: name)
    }
    // Strip inline event handlers (onclick, onerror, onload…). JS is enabled in
    // the reader for our own scroll script, so book content must not be able to
    // run script via attributes.
    for attribute in element.attributes ?? [] {
        guard let name = attribute.name, name.lowercased().hasPrefix("on") else { continue }
        element.removeAttribute(forName: name)
    }

    switch element.localName?.lowercased() {
    case "img":
        rewriteResourceAttribute(element, named: "src", spineDir: spineDir)
        // Only fetch/decode images as they approach the viewport — keeps a
        // big, image-heavy book from loading every image up front.
        setAttribute(element, name: "loading", value: "lazy")
        setAttribute(element, name: "decoding", value: "async")
    case "source":
        rewriteResourceAttribute(element, named: "src", spineDir: spineDir)
    case "image":
        rewriteResourceAttribute(element, named: "href", spineDir: spineDir)
        rewriteResourceAttribute(element, named: "xlink:href", spineDir: spineDir)
    case "a":
        rewriteAnchor(element, spineDir: spineDir, spineIndexByPath: spineIndexByPath)
    default:
        break
    }

    var toRemove: [XMLElement] = []
    for child in element.children ?? [] {
        guard let childElement = child as? XMLElement else { continue }
        // Drop scripts, the book's own styles, and remote-content embeds.
        if ["script", "style", "link", "iframe", "object", "embed"].contains(
            childElement.localName?.lowercased())
        {
            toRemove.append(childElement)
        } else {
            sanitize(childElement, spineDir: spineDir, spineIndexByPath: spineIndexByPath)
        }
    }
    for node in toRemove { node.detach() }
}

/// Rewrites a resource URL (image/source) from book-relative to a
/// `tomo-epub://` URL the loader resolves out of the zip.
private nonisolated func rewriteResourceAttribute(
    _ element: XMLElement, named name: String, spineDir: String
) {
    guard let value = element.attribute(forName: name)?.stringValue, !value.isEmpty,
        !value.hasPrefix("data:")
    else { return }
    let resolved = EPUBArchive.resolvePath(value, baseDir: spineDir)
    guard let url = EPUBReaderScheme.url(forArchivePath: resolved) else { return }
    setAttribute(element, name: name, value: url.absoluteString)
}

/// Rewrites links for whole-book scroll: internal links become in-document
/// anchors (`#ch-N` or `#fragment`); external links are left for the reader
/// to open in the browser; unresolved internal links are made inert.
private nonisolated func rewriteAnchor(
    _ element: XMLElement, spineDir: String, spineIndexByPath: [String: Int]
) {
    guard let href = element.attribute(forName: "href")?.stringValue, !href.isEmpty else {
        return
    }
    let lower = href.lowercased()
    if lower.hasPrefix("http://") || lower.hasPrefix("https://")
        || lower.hasPrefix("mailto:") || lower.hasPrefix("tel:")
    {
        return
    }

    let fragment: String
    let filePart: String
    if let hashIndex = href.firstIndex(of: "#") {
        filePart = String(href[..<hashIndex])
        fragment = String(href[href.index(after: hashIndex)...])
    } else {
        filePart = href
        fragment = ""
    }

    // Pure in-page anchor (#note) — already valid in the combined document.
    if filePart.isEmpty {
        if isFootnoteReference(element) {
            setAttribute(element, name: "data-footnote", value: fragment)
        }
        return
    }

    let resolved = EPUBArchive.resolvePath(filePart, baseDir: spineDir)
    if !fragment.isEmpty {
        // The fragment's id is preserved in the merged document.
        setAttribute(element, name: "href", value: "#\(fragment)")
        // Footnote references get a popover instead of a place-losing jump. The
        // runtime JS keys off this attribute; the href stays as the fallback.
        if isFootnoteReference(element) {
            setAttribute(element, name: "data-footnote", value: fragment)
        }
    } else if let index = spineIndexByPath[resolved] {
        setAttribute(element, name: "href", value: "#ch-\(index)")
    } else {
        // Target isn't part of the readable spine — drop the link target.
        element.removeAttribute(forName: "href")
    }
}

/// Whether an in-page anchor is a footnote/endnote reference (so it should
/// open in a popover rather than jump). Detection, in order of confidence:
/// EPUB3 semantics (`epub:type`/`role`), then a `<sup>` wrapper/child, then a
/// bare footnote-marker text (`1`, `[1]`, `*`, `†`). Prose cross-references
/// ("see Chapter 3") match none of these and keep their navigation behaviour.
nonisolated func isFootnoteReference(_ element: XMLElement) -> Bool {
    if let epubType = element.attribute(forName: "epub:type")?.stringValue {
        let tokens = epubType.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" })
        if tokens.contains("noteref") { return true }
    }
    if element.attribute(forName: "role")?.stringValue?.lowercased() == "doc-noteref" {
        return true
    }

    if (element.parent as? XMLElement)?.localName?.lowercased() == "sup" { return true }
    if let sups = try? element.nodes(forXPath: ".//*[local-name()='sup']"), !sups.isEmpty {
        return true
    }

    let text = (element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty, text.count <= 6,
        text.wholeMatch(of: /^[\[(]?\s*[\d*†‡§¶]+\s*[\])]?$/) != nil
    {
        return true
    }
    return false
}

private nonisolated func setAttribute(_ element: XMLElement, name: String, value: String) {
    element.removeAttribute(forName: name)
    if let attribute = XMLNode.attribute(withName: name, stringValue: value) as? XMLNode {
        element.addAttribute(attribute)
    }
}

// MARK: - Stylesheet

/// The reader's typography. The book's own CSS is dropped; this governs
/// everything. A measured column (~62ch per Tschichold), a warm serif palette
/// that adapts to appearance, generous rhythm, and restrained links — content
/// treated like a well-set article, not a raw EPUB dump.
private nonisolated let readerCSS = """
    :root {
      color-scheme: light dark;
      --fg: #232019;
      --bg: #f6f4f0;
      --muted: #6f6a60;
      --rule: rgba(0,0,0,0.12);
      --accent: #8a5a2b;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --fg: #d8d4cc;
        --bg: #100f12;
        --muted: #8d887e;
        --rule: rgba(255,255,255,0.14);
        --accent: #cda06d;
      }
    }
    * { box-sizing: border-box; }
    html { -webkit-text-size-adjust: 100%; background: var(--bg); }
    body {
      margin: 0;
      background: var(--bg);
      color: var(--fg);
      font-family: ui-serif, "New York", Iowan Old Style, Georgia, serif;
      font-size: 1.25rem;
      line-height: 1.72;
      font-kerning: normal;
      font-feature-settings: "kern" 1, "liga" 1, "onum" 1, "pnum" 1;
      text-rendering: optimizeLegibility;
      -webkit-font-smoothing: antialiased;
    }
    .reader {
      max-width: 62ch;
      margin: 0 auto;
      padding: 6rem 1.5rem 14rem;
      hyphens: auto;
      -webkit-hyphens: auto;
    }
    .reader p { margin: 0 0 1.35em; text-align: left; }
    .reader h1, .reader h2, .reader h3, .reader h4, .reader h5, .reader h6 {
      font-weight: 600;
      line-height: 1.2;
      margin: 2.4em 0 0.8em;
      text-wrap: balance;
    }
    .reader h1 { font-size: 1.95rem; letter-spacing: -0.01em; }
    .reader h2 { font-size: 1.5rem; }
    .reader h3 { font-size: 1.25rem; }
    .reader h4, .reader h5, .reader h6 { font-size: 1.05rem; }
    .reader a {
      color: var(--accent);
      text-decoration: none;
      border-bottom: 1px solid var(--rule);
    }
    .reader img, .reader svg {
      display: block;
      max-width: 100%;
      height: auto;
      margin: 2rem auto;
    }
    .reader figure { margin: 2rem 0; }
    .reader figcaption {
      font-size: 0.85rem;
      color: var(--muted);
      text-align: center;
      margin-top: 0.6rem;
    }
    .reader blockquote {
      margin: 1.6em 0;
      padding-left: 1.1em;
      border-left: 2px solid var(--rule);
      color: var(--muted);
      font-style: italic;
    }
    .reader hr {
      border: none;
      height: 1px;
      background: var(--rule);
      width: 38%;
      margin: 3em auto;
    }
    .reader ul, .reader ol { margin: 0 0 1.35em; padding-left: 1.5em; }
    .reader li { margin: 0.3em 0; }
    .reader sup, .reader sub { line-height: 0; }
    .reader code, .reader pre {
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 0.88em;
    }
    .reader pre {
      white-space: pre-wrap;
      overflow-x: auto;
      background: rgba(127,127,127,0.10);
      padding: 1em;
      border-radius: 8px;
    }
    .reader table {
      width: 100%;
      border-collapse: collapse;
      margin: 1.5em 0;
      font-size: 0.95em;
    }
    .reader th, .reader td {
      border: 1px solid var(--rule);
      padding: 0.4em 0.6em;
      text-align: left;
    }
    .reader .chapter + .chapter {
      margin-top: 6rem;
      padding-top: 6rem;
      border-top: 1px solid var(--rule);
    }
    .reader a[data-footnote] {
      cursor: pointer;
      font-size: 0.72em;
      vertical-align: super;
      line-height: 0;
      border-bottom: none;
      font-weight: 600;
    }
    /* Source already raised it (wrapped in <sup>/<sub>) — don't compound. */
    .reader sup a[data-footnote], .reader sub a[data-footnote] {
      font-size: inherit;
      vertical-align: baseline;
    }
    .tomo-fn-backdrop {
      position: fixed;
      inset: 0;
      z-index: 9998;
      background: transparent;
    }
    .tomo-fn-popover {
      position: fixed;
      z-index: 9999;
      max-width: min(38ch, calc(100vw - 2rem));
      max-height: 40vh;
      overflow-y: auto;
      overscroll-behavior: contain;
      padding: 1rem 1.15rem;
      background: var(--bg);
      color: var(--fg);
      border: 1px solid var(--rule);
      border-radius: 12px;
      box-shadow: 0 1px 2px rgba(0,0,0,0.12), 0 8px 28px rgba(0,0,0,0.22);
      font-family: ui-serif, "New York", Iowan Old Style, Georgia, serif;
      font-size: 1rem;
      line-height: 1.6;
    }
    .tomo-fn-popover > :first-child { margin-top: 0; }
    .tomo-fn-popover > :last-child { margin-bottom: 0; }
    .tomo-fn-popover p { margin: 0 0 0.7em; }
    """
