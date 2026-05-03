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
    /// language entry.
    let language: String
    /// HTML chunks in reading order. Each chunk is the *inner* HTML
    /// of one spine document's `<body>` — without `<html>`, `<head>`,
    /// or `<body>` wrappers. The skeleton template wraps each chunk
    /// with the structural HTML the KF8 reader expects.
    let chunks: [String]
}
