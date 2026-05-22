import AZW3
import Foundation

/// Bridges Tomo's EPUB pipeline to the AZW3 writer. Reads an EPUB
/// off disk via `EPUBSource`, hands the resulting `BookManifest` to
/// `AZW3Writer`, and writes the produced bytes into the conversion
/// scratch directory.
nonisolated struct EPUBToAZW3Converter: FormatConverter {
    let input: FileFormat = .epub
    let output: FileFormat = .azw3

    func convert(source: URL, into scratchDir: URL) async throws -> URL {
        try await convert(source: source, into: scratchDir, coverSource: .epub)
    }

    /// EPUB-specific entry point that lets the delivery layer override
    /// the cover (so user cover edits — including explicit removal —
    /// reach the AZW3 instead of the writer always picking the EPUB's
    /// embedded cover).
    func convert(
        source: URL,
        into scratchDir: URL,
        coverSource: EPUBSource.CoverSource
    ) async throws -> URL {
        // Both `EPUBSource.read` and `AZW3Writer.encode()` are
        // synchronous and `nonisolated`; calling them from this
        // async method runs them on the cooperative pool without
        // any task-hop ceremony.
        let manifest = try EPUBSource.read(from: source, coverSource: coverSource)
        let bytes = AZW3Writer(manifest: manifest).encode()

        let outputURL =
            scratchDir
            .appending(
                component: source.deletingPathExtension().lastPathComponent
                    + "." + output.rawValue)
        try bytes.write(to: outputURL)
        return outputURL
    }
}
