import Foundation

/// Renders a `BookManifest` into the combined-text byte stream + chunk
/// and chapter geometry that the rest of the writer consumes.
///
/// Each chunk gets a fresh skeleton document (the structural HTML
/// scaffolding) emitted into the stream, immediately followed by the
/// chunk's body content. Kindle's KF8 reader stitches them back
/// together using the chunk and skeleton INDX records.
///
/// CSS bytes are appended to the combined text *after* all HTML chunks.
/// FDST entries (built by the writer) describe the HTML range and one
/// range per CSS flow.
nonisolated enum Markup {

    static func chaptersToText(_ manifest: BookManifest) -> (
        text: Data,
        chunks: [ChunkInfo],
        chapters: [ChapterInfo]
    ) {
        var text = Data()
        var chunks: [ChunkInfo] = []
        chunks.reserveCapacity(manifest.chunks.count)

        for (i, chunkBody) in manifest.chunks.enumerated() {
            let head = skeletonTemplate(
                title: manifest.title,
                chunkAID: i,
                cssFlowCount: manifest.cssFlows.count
            )
            let headBytes = Data(head.utf8)
            let bodyBytes = Data(chunkBody.utf8)

            chunks.append(ChunkInfo(
                preStart: text.count,
                preLength: headBytes.count,
                contentStart: text.count + headBytes.count,
                contentLength: bodyBytes.count
            ))

            text.append(headBytes)
            text.append(bodyBytes)
        }

        // Chapters cover the HTML portion only — build them before
        // appending CSS so byte ranges line up with chunks.
        let chapters = buildChapters(
            toc: manifest.toc,
            chunks: chunks,
            textLength: text.count,
            fallbackTitle: manifest.title
        )

        // CSS flows: append after HTML. AZW3Writer reads
        // `manifest.cssFlows` separately to build FDST entries.
        for flow in manifest.cssFlows {
            text.append(Data(flow.utf8))
        }

        return (text, chunks, chapters)
    }
}

/// Maps `TocEntry`s into byte-range `ChapterInfo`s for the NCX.
///
/// - Multiple TOC entries pointing into the same chunk collapse to the
///   first (anchor-level granularity within a spine document is not
///   represented in v1).
/// - The first chapter is extended back to byte 0 so the NCX covers
///   any front matter (cover, title page) that isn't itself a TOC entry.
/// - The last chapter extends to the end of the HTML text.
/// - Empty TOC produces a single fallback chapter spanning the whole HTML.
private nonisolated func buildChapters(
    toc: [TocEntry],
    chunks: [ChunkInfo],
    textLength: Int,
    fallbackTitle: String
) -> [ChapterInfo] {
    let valid = toc.filter { $0.chunkIndex >= 0 && $0.chunkIndex < chunks.count }

    var seen: Set<Int> = []
    var unique: [TocEntry] = []
    for entry in valid {
        if seen.insert(entry.chunkIndex).inserted {
            unique.append(entry)
        }
    }
    let sorted = unique.sorted { $0.chunkIndex < $1.chunkIndex }

    if sorted.isEmpty {
        return [ChapterInfo(title: fallbackTitle, start: 0, length: textLength)]
    }

    var result: [ChapterInfo] = []
    result.reserveCapacity(sorted.count)
    for (i, entry) in sorted.enumerated() {
        let start = i == 0 ? 0 : chunks[entry.chunkIndex].preStart
        let nextStart = i + 1 < sorted.count
            ? chunks[sorted[i + 1].chunkIndex].preStart
            : textLength
        result.append(ChapterInfo(
            title: entry.title,
            start: start,
            length: nextStart - start
        ))
    }
    return result
}

/// Skeleton template — a fixed XHTML document with an empty `<body>`
/// element carrying the chunk's `aid` attribute. The chunk body bytes
/// are appended *after* this string, not inside `<body>`.
///
/// One `<link rel="stylesheet">` is injected per CSS flow, pointing at
/// the corresponding `kindle:flow:NNNN` URI (1-based decimal, padded
/// to 4 digits — matches Calibre's KF8 output).
private nonisolated func skeletonTemplate(
    title: String, chunkAID: Int, cssFlowCount: Int
) -> String {
    var links = ""
    if cssFlowCount > 0 {
        let tags = (1...cssFlowCount).map { i in
            let flowID = String(format: "%04d", i)
            return "<link rel=\"stylesheet\" type=\"text/css\" href=\"kindle:flow:\(flowID)?mime=text/css\"/>"
        }
        links = "\n    " + tags.joined(separator: "\n    ")
    }
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml">
      <head>
        <title>\(title)</title>
        <meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>\(links)
      </head>
      <body aid="\(to32(chunkAID))">
      </body>
    </html>
    """
}
