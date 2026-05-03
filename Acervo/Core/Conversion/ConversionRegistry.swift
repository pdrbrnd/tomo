import Foundation

/// Lookup table for converters. Devices ask the registry "do you have a
/// path from format A to format B?" and get either a converter or nil.
/// To add a format adapter, append it to `default`'s converter list. To
/// retire one, remove it from the same list — devices that no longer have
/// a viable adapter throw at copy time, and old adapter source can be
/// deleted with no remaining callers.
nonisolated struct ConversionRegistry: Sendable {
    private let converters: [any FormatConverter]

    init(_ converters: [any FormatConverter] = []) {
        self.converters = converters
    }

    func converter(from input: BookFormat, to output: BookFormat) -> (any FormatConverter)? {
        converters.first { $0.input == input && $0.output == output }
    }

    /// Process-wide registry. The list is empty until a real converter is
    /// added (see `Core/Conversion/AZW3/` for the EPUB→AZW3 port). Edit this
    /// single line to add or retire a format adapter.
    static let `default` = ConversionRegistry()
}
