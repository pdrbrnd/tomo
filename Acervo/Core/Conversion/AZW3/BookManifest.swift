import Foundation

/// The AZW3 writer's public input — a plain Sendable description of a
/// book ready to be encoded. Anyone using the writer (today: Acervo's
/// `EPUBToAZW3Converter`; tomorrow: any Swift caller in any other
/// project) constructs one of these and hands it off.
///
/// This type is part of the AZW3 writer's public surface area and
/// will move with it when the writer is extracted to its own package.
/// **Do not reference any Acervo type here** — keep it Foundation-only
/// so the package extraction stays a pure file move.
nonisolated struct BookManifest: Sendable, Equatable {
    /// User-facing title.
    let title: String
    /// Author names in display order. Empty array allowed but Kindle
    /// shows "Unknown Author" if you do that.
    let authors: [String]
    /// BCP 47 tag (`pt-PT`, `en-GB`, `und`, etc.). Drives the EXTH
    /// language entry and the MOBI header locale code.
    let language: String
    /// HTML chunks in reading order. Each chunk is the *inner* HTML
    /// of one spine document's `<body>` — without `<html>`, `<head>`,
    /// or `<body>` wrappers. The skeleton template wraps each chunk
    /// with the structural HTML the KF8 reader expects.
    let chunks: [String]

    /// Cover image, if available. Drives the cover image record and
    /// EXTH cover offset / has-fake-cover entries.
    let cover: ImageData?
    /// Body images referenced from `chunks` via `kindle:embed:NNNN`
    /// URIs. Each entry's array index (1-based, with cover at 0)
    /// drives the URI's NNNN part — caller is responsible for having
    /// rewritten the chunks to point at these indices.
    let bodyImages: [ImageData]
    /// CSS files in OPF manifest order. Bytes are appended to the
    /// combined text after HTML; the skeleton template references them
    /// via `kindle:flow:NNNN` URIs.
    let cssFlows: [String]
    /// Table-of-contents entries pointing into `chunks`. Empty array
    /// produces a single fallback NCX entry covering the whole book.
    let toc: [TocEntry]
    /// `<dc:date>` from the OPF, if parseable. Drives EXTH publishing
    /// date when present.
    let publishingDate: Date?
    /// `<dc:identifier>` from the OPF. Used as the MOBI uniqueID seed
    /// when present, falling back to a stable hash of title+authors.
    let identifier: String?

    init(
        title: String,
        authors: [String],
        language: String,
        chunks: [String],
        cover: ImageData? = nil,
        bodyImages: [ImageData] = [],
        cssFlows: [String] = [],
        toc: [TocEntry] = [],
        publishingDate: Date? = nil,
        identifier: String? = nil
    ) {
        self.title = title
        self.authors = authors
        self.language = language
        self.chunks = chunks
        self.cover = cover
        self.bodyImages = bodyImages
        self.cssFlows = cssFlows
        self.toc = toc
        self.publishingDate = publishingDate
        self.identifier = identifier
    }
}

/// An image to embed in the AZW3 (cover today; body images in Phase 2B).
nonisolated struct ImageData: Sendable, Equatable {
    /// Raw image bytes. JPEG, PNG, or GIF — KF8 supports all three.
    let bytes: Data
    /// MIME type — "image/jpeg", "image/png", or "image/gif".
    let mimeType: String
}

/// One TOC entry. `chunkIndex` selects which chunk in `BookManifest.chunks`
/// the chapter starts at; finer-grained anchors mid-chunk are not
/// represented (multiple TOC entries pointing into the same chunk
/// collapse to the first).
nonisolated struct TocEntry: Sendable, Equatable {
    let title: String
    let chunkIndex: Int
}
