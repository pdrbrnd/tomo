import Foundation

/// File-format identifier used by the conversion layer. Cases are added as
/// real converters land — there's no point representing a format the app
/// can't either consume or produce.
nonisolated enum FileFormat: String, Hashable, Sendable {
    case epub
    case azw3
}

/// One-shot conversion from a single input format to a single output format.
/// Concrete converters live in `Core/Conversion/` (e.g.
/// `Core/Conversion/EPUBToAZW3Converter.swift`) and bridge between Acervo
/// types and a writer (the writer itself sits under `AZW3/` and stays free
/// of Acervo types — see `AZW3/README.md`). Converters never touch the
/// library folder; they write into a caller-provided scratch directory and
/// return the URL of the produced file. The file's name should be
/// `<source-stem>.<output.rawValue>`.
nonisolated protocol FormatConverter: Sendable {
    var input: FileFormat { get }
    var output: FileFormat { get }
    func convert(source: URL, into scratchDir: URL) async throws -> URL
}

/// Errors raised by the conversion layer itself. Concrete converters may
/// also throw their own typed errors for format-specific failures.
enum FormatConverterError: LocalizedError {
    /// No converter is registered for the requested pair, or the input
    /// extension isn't a recognised `FileFormat` at all.
    case unsupported(input: String, output: FileFormat)

    var errorDescription: String? {
        switch self {
        case .unsupported(let input, let output):
            "No converter available from \(input) to \(output.rawValue)."
        }
    }
}
