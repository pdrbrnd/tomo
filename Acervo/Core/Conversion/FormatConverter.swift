import Foundation

/// Identifier for a file format used by the conversion layer. String-backed
/// (not an enum) so that adapters for new formats can be added without
/// touching this file. Lowercase canonical form matches the extension
/// strings used in `BookDevice.supportedFormats`.
nonisolated struct BookFormat: Hashable, Sendable {
    let rawValue: String

    init(_ rawValue: String) { self.rawValue = rawValue.lowercased() }

    static let epub = BookFormat("epub")
    static let azw3 = BookFormat("azw3")
    static let pdf  = BookFormat("pdf")
    static let txt  = BookFormat("txt")
}

/// One-shot conversion from a single input format to a single output format.
/// Implementations live under `Core/Conversion/<TargetFormat>/` (e.g.
/// `Core/Conversion/AZW3/EPUBToAZW3Converter.swift`). They never touch the
/// library folder; they write into a caller-provided scratch directory and
/// return the URL of the produced file. The file's name should be
/// `<source-stem>.<output.rawValue>`.
nonisolated protocol FormatConverter: Sendable {
    var input: BookFormat { get }
    var output: BookFormat { get }
    func convert(source: URL, into scratchDir: URL) async throws -> URL
}

/// Errors raised by the conversion layer itself. Concrete converters may
/// also throw their own typed errors for format-specific failures.
enum FormatConverterError: LocalizedError {
    case unsupported(input: BookFormat, output: BookFormat)

    var errorDescription: String? {
        switch self {
        case .unsupported(let input, let output):
            "No converter available from \(input.rawValue) to \(output.rawValue)."
        }
    }
}
