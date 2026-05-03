import Foundation

/// Renders a `BookManifest` into the combined-text byte stream + chunk
/// and chapter geometry that the rest of the writer consumes.
///
/// Each chunk gets a fresh skeleton document (the structural HTML
/// scaffolding) emitted into the stream, immediately followed by the
/// chunk's body content. Kindle's KF8 reader stitches them back
/// together using the chunk and skeleton INDX records.
///
/// Phase 1 simplification: one chapter spans the whole book (no TOC
/// extracted from the EPUB yet). Each manifest chunk becomes one
/// chunk in the writer's chunk list. Multi-chapter / multi-chunk
/// support arrives in Phase 2 alongside NCX-from-EPUB-nav extraction.
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
            let head = skeletonTemplate(title: manifest.title, chunkAID: i)
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

        // Phase 1: one chapter spanning the entire text. The Kindle
        // home screen still works without real chapters; the NCX
        // record just becomes a one-entry "Whole book" pointer.
        let chapter = ChapterInfo(
            title: manifest.title,
            start: 0,
            length: text.count
        )

        return (text, chunks, [chapter])
    }
}

/// Phase 1 skeleton template — a fixed XHTML document with an empty
/// `<body>` element carrying the chunk's `aid` attribute. The chunk
/// body bytes are appended *after* this string, not inside `<body>`.
/// Kindle's KF8 parser uses the chunk INDX to slice the bytes back
/// into the right places.
///
/// Phase 2: replace with a proper template engine when CSS flows
/// land — each `<link>` element references `kindle:flow:N` URIs
/// injected by the writer. For now: no CSS, no link tags.
private nonisolated func skeletonTemplate(title: String, chunkAID: Int) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml">
      <head>
        <title>\(title)</title>
        <meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
      </head>
      <body aid="\(to32(chunkAID))">
      </body>
    </html>
    """
}
