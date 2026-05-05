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
        // Both `EPUBSource.read` and `AZW3Writer.encode()` are
        // synchronous and `nonisolated`; calling them from this
        // async method runs them on the cooperative pool without
        // any task-hop ceremony.
        let manifest = try EPUBSource.read(from: source)
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
