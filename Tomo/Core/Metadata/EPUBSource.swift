import AZW3
import Foundation
import os

/// Reads an EPUB and produces a `BookManifest` ready for the AZW3 writer.
nonisolated enum EPUBSource {

    /// Where the manifest's cover bytes come from. Callers that don't
    /// care (tests, generic conversion) use `.epub`. The delivery path
    /// uses `.override` so that user cover edits — including explicit
    /// "Remove Cover" (URL nil) — reach the AZW3 and the Kindle
    /// home-screen thumbnail.
    enum CoverSource: Sendable {
        case epub
        case override(URL?)
    }

    static func read(from url: URL, coverSource: CoverSource = .epub) throws -> BookManifest {
        let epub = try EPUBArchive.open(url)
        guard let title = epub.opf.title else {
            throw EPUBArchiveError.missingTitle
        }

        // Pass 1: pull each spine item's body inner HTML.
        var rawChunks: [String] = []
        var spineDirs: [String] = []
        var spinePathToChunk: [String: Int] = [:]
        for href in epub.opf.spineHrefs {
            guard let data = epub.data(forResourceHref: href) else { continue }
            guard let inner = bodyInnerHTML(from: data) else { continue }
            let archivePath = EPUBArchive.resolvePath(href, baseDir: epub.opfDir)
            spinePathToChunk[archivePath] = rawChunks.count
            rawChunks.append(inner)
            spineDirs.append((archivePath as NSString).deletingLastPathComponent)
        }
        guard !rawChunks.isEmpty else {
            throw EPUBArchiveError.noReadableContent
        }

        // Pass 2: rewrite `<img src>` to `kindle:embed:NNNN` and collect
        // the referenced body images.
        let cover: ImageData? =
            switch coverSource {
            case .epub: extractCover(from: epub)
            case .override(let url): loadOverrideCover(url: url)
            }
        let coverArchivePath = epub.opf.coverItem.map {
            EPUBArchive.resolvePath($0.href, baseDir: epub.opfDir)
        }
        let (chunks, bodyImages) = rewriteAndCollectBodyImages(
            chunks: rawChunks,
            spineDirs: spineDirs,
            epub: epub,
            coverPresent: cover != nil,
            coverArchivePath: coverArchivePath
        )

        // CSS flows in OPF manifest order.
        let cssFlows: [String] = epub.opf.manifest.compactMap { item in
            guard item.mediaType == "text/css",
                let data = epub.data(forResourceHref: item.href),
                let text = String(data: data, encoding: .utf8)
            else { return nil }
            return text
        }

        // TOC: parse nav.xhtml or toc.ncx, map each entry to a chunk index.
        let toc: [TocEntry] = EPUBNavigation.parse(in: epub).compactMap { entry in
            guard let chunkIndex = spinePathToChunk[entry.resourcePath] else {
                return nil
            }
            return TocEntry(title: entry.title, chunkIndex: chunkIndex)
        }

        return BookManifest(
            title: title,
            authors: epub.opf.authors,
            language: epub.opf.language ?? "und",
            chunks: chunks,
            cover: cover,
            bodyImages: bodyImages,
            cssFlows: cssFlows,
            toc: toc,
            publishingDate: epub.opf.date.flatMap(parseEPUBDate),
            identifier: epub.opf.identifier
        )
    }
}

// MARK: - Cover extraction

/// Loads a user-edited cover from disk for the override path. JPEG/PNG/GIF
/// are passed through; other formats (HEIC, TIFF, WebP) are re-encoded to
/// JPEG because the AZW3 cover record only supports the three KF8-native
/// types. Returns nil when the URL is nil (user removed the cover), the
/// file is unreadable, or the bytes can't be decoded as an image — in
/// every case the manifest carries no cover, which is the correct
/// "manual override always wins" outcome.
private nonisolated func loadOverrideCover(url: URL?) -> ImageData? {
    guard let url else { return nil }
    guard let bytes = try? Data(contentsOf: url) else {
        metadataLogger.warning(
            "cover override unreadable: \(url.path, privacy: .public)")
        return nil
    }
    let mime = mimeFromExtension(url.path)
    switch mime {
    case "image/jpeg", "image/png", "image/gif":
        return ImageData(bytes: bytes, mimeType: mime)
    default:
        guard let jpeg = CoverRasterizer.reencodeToJPEG(bytes) else {
            metadataLogger.warning(
                "cover override could not be decoded; dropping (was \(mime, privacy: .public))")
            return nil
        }
        return ImageData(bytes: jpeg, mimeType: "image/jpeg")
    }
}

private nonisolated func extractCover(from epub: EPUBArchive) -> ImageData? {
    guard let item = epub.opf.coverItem else { return nil }
    guard let bytes = epub.data(forResourceHref: item.href) else {
        metadataLogger.error("cover entry missing: \(item.href, privacy: .public)")
        return nil
    }
    let mime = imageMimeType(for: item)
    switch mime {
    case "image/jpeg", "image/png", "image/gif":
        return ImageData(bytes: bytes, mimeType: mime)
    case "image/svg+xml":
        guard let jpeg = CoverRasterizer.rasterizeSVG(bytes) else {
            metadataLogger.warning("could not rasterise SVG cover; dropping")
            return nil
        }
        return ImageData(bytes: jpeg, mimeType: "image/jpeg")
    default:
        metadataLogger.warning("unsupported cover mime: \(mime, privacy: .public)")
        return nil
    }
}

private nonisolated func imageMimeType(for item: ManifestItem) -> String {
    if !item.mediaType.isEmpty { return item.mediaType }
    return mimeFromExtension(item.href)
}

private nonisolated func mimeFromExtension(_ path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "gif": return "image/gif"
    case "svg": return "image/svg+xml"
    default: return "application/octet-stream"
    }
}

// MARK: - Body image extraction + chunk rewriting

private nonisolated func rewriteAndCollectBodyImages(
    chunks: [String],
    spineDirs: [String],
    epub: EPUBArchive,
    coverPresent: Bool,
    coverArchivePath: String?
) -> (chunks: [String], bodyImages: [ImageData]) {
    // Regex<...> isn't Sendable in Swift 6, so build it locally.
    let imgSrcPattern = /src\s*=\s*(?:"([^"]+)"|'([^']+)')/

    // Image manifest items keyed by archive-absolute path.
    var imageItemByPath: [String: ManifestItem] = [:]
    for item in epub.opf.manifest where item.mediaType.hasPrefix("image/") {
        let path = EPUBArchive.resolvePath(item.href, baseDir: epub.opfDir)
        imageItemByPath[path] = item
    }

    // Walk chunks once to discover body images in encounter order.
    var bodyImagePaths: [String] = []
    var seen: Set<String> = coverArchivePath.map { [$0] } ?? []
    for (chunk, spineDir) in zip(chunks, spineDirs) {
        for match in chunk.matches(of: imgSrcPattern) {
            let url =
                match.output.1.map(String.init)
                ?? match.output.2.map(String.init)
                ?? ""
            let resolved = EPUBArchive.resolvePath(url, baseDir: spineDir)
            guard imageItemByPath[resolved] != nil,
                seen.insert(resolved).inserted
            else { continue }
            bodyImagePaths.append(resolved)
        }
    }

    // Image array: cover at index 0 (if present) then body images.
    // Kindle's `kindle:embed:NNNN` URI is 1-based.
    var pathToEmbedIndex: [String: Int] = [:]
    if let cover = coverArchivePath {
        pathToEmbedIndex[cover] = 1
    }
    let bodyStart = coverPresent ? 2 : 1
    for (i, path) in bodyImagePaths.enumerated() {
        pathToEmbedIndex[path] = bodyStart + i
    }

    // Rewrite each chunk's src URLs.
    let rewritten = zip(chunks, spineDirs).map { (chunk, spineDir) -> String in
        chunk.replacing(imgSrcPattern) { match in
            let url =
                match.output.1.map(String.init)
                ?? match.output.2.map(String.init)
                ?? ""
            let resolved = EPUBArchive.resolvePath(url, baseDir: spineDir)
            guard let embedIndex = pathToEmbedIndex[resolved] else {
                return String(match.output.0)
            }
            return "src=\"kindle:embed:\(String(format: "%04X", embedIndex))\""
        }
    }

    // Read body image bytes.
    var bodyImages: [ImageData] = []
    for path in bodyImagePaths {
        guard let bytes = epub.data(at: path) else { continue }
        let mime = imageItemByPath[path]?.mediaType ?? mimeFromExtension(path)
        bodyImages.append(ImageData(bytes: bytes, mimeType: mime))
    }

    return (rewritten, bodyImages)
}

// MARK: - Body inner HTML

/// Extracts the inner HTML of the `<body>` element. Slices the raw bytes
/// between the literal start and end tags, preserving the EPUB's exact
/// whitespace, namespace declarations, and entity escaping. Falls back
/// to an `XMLDocument` round-trip for malformed inputs.
private nonisolated func bodyInnerHTML(from data: Data) -> String? {
    if let sliced = bodyInnerHTMLByByteSlice(data) {
        return sliced
    }
    return bodyInnerHTMLByXMLDocument(data)
}

private nonisolated func bodyInnerHTMLByByteSlice(_ data: Data) -> String? {
    let openMarker = Data("<body".utf8)
    let closeMarker = Data("</body".utf8)
    let gtByte: UInt8 = 0x3E  // '>'
    let slashByte: UInt8 = 0x2F  // '/'

    guard let openRange = data.firstRange(of: openMarker) else { return nil }

    guard let gtIndex = data[openRange.upperBound...].firstIndex(of: gtByte) else {
        return nil
    }

    if gtIndex > openRange.upperBound, data[gtIndex - 1] == slashByte {
        return ""
    }

    let innerStart = data.index(after: gtIndex)
    guard innerStart < data.endIndex,
        let closeRange = data[innerStart...].lastRange(of: closeMarker)
    else { return nil }

    return String(data: data[innerStart..<closeRange.lowerBound], encoding: .utf8)
}

private nonisolated func bodyInnerHTMLByXMLDocument(_ data: Data) -> String? {
    guard let doc = parseXHTMLOrTidy(data), let root = doc.rootElement() else { return nil }
    let bodies = (try? doc.nodes(forXPath: "//*[local-name()='body']")) ?? []
    let body = (bodies.first as? XMLElement) ?? findBody(in: root)
    guard let body else { return nil }

    return (body.children ?? [])
        .map { $0.xmlString(options: [.nodePreserveCDATA]) }
        .joined()
}

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
