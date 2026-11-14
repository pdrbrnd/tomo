import Foundation

/// Kindle behaviour that doesn't depend on how the bytes reach the device.
/// Shared by the USB-mass-storage driver (`Kindle`) and the MTP driver
/// (`KindleMTP`), which differ only in transport.
nonisolated enum KindleDelivery {
    /// Kindle's home-screen scanner ignores EPUB regardless of firmware.
    /// The renderer reads EPUB on FW 5.16+, but the scanner that builds
    /// the library list from `/documents/` only indexes Amazon-friendly
    /// formats. EPUBs are converted to AZW3 on the fly via the
    /// conversion adapter — see `Tomo/Core/Conversion/`.
    static let supportedFormats: Set<String> = ["azw", "azw3", "mobi", "prc", "pdf", "txt"]

    /// Produces the file to put on the device — the library file itself
    /// for passthrough, or a converted copy in a scratch directory — and
    /// hands it to `deliver`. The scratch copy only lives for the duration
    /// of the call.
    ///
    /// Returns true when the book was converted from EPUB, i.e. when the
    /// caller should also write a home-screen cover thumbnail.
    static func withDeliverableFile(
        for book: Book,
        route: DeliveryRoute?,
        _ deliver: @Sendable (URL) async throws -> Void
    ) async throws -> Bool {
        switch route {
        case .passthrough:
            try await deliver(book.fileURL)
            return false

        case .convert(let target):
            // The route helper already verified a converter exists,
            // but we fetch it again here for the actual call. Source
            // format is guaranteed to round-trip since we just got
            // back a non-nil route.
            let sourceExt = book.fileURL.pathExtension.lowercased()
            guard let sourceFormat = FileFormat(rawValue: sourceExt),
                let converter = ConversionRegistry.default
                    .converter(from: sourceFormat, to: target)
            else {
                throw BookDeviceError.copyFailed(
                    underlying: FormatConverterError.unsupported(
                        input: sourceExt, output: target
                    )
                )
            }
            try await ConversionScratch.withScratchDirectory { scratch in
                // For EPUB→AZW3, route through the EPUB-specific overload
                // so the user's on-disk cover override (or its explicit
                // removal) flows into both the AZW3 cover record and the
                // home-screen thumbnail. Other source formats keep the
                // generic registry path.
                let converted: URL
                if let epubConverter = converter as? EPUBToAZW3Converter {
                    converted = try await epubConverter.convert(
                        source: book.fileURL,
                        into: scratch,
                        coverSource: .override(book.coverURL),
                        metadata: EPUBSource.MetadataOverride(
                            title: book.title,
                            authors: book.authors.isEmpty ? nil : book.authors,
                            language: book.locale
                        )
                    )
                } else {
                    converted = try await converter.convert(source: book.fileURL, into: scratch)
                }
                try await deliver(converted)
            }
            return sourceFormat == .epub

        case .none:
            throw BookDeviceError.copyFailed(
                underlying: FormatConverterError.unsupported(
                    input: book.fileURL.pathExtension.lowercased(),
                    output: .azw3
                )
            )
        }
    }

    /// Pre-installed Kindle content we don't want users deleting accidentally
    /// (or — for dictionaries — content that's recoverable but better managed
    /// via the on-device Settings flow). The `supportedFormats` whitelist
    /// already filters non-book extensions, so this only needs to catch
    /// things that *look* like books but aren't user content.
    ///
    /// Two layers:
    ///  - exact stem matches for well-known Amazon files (`My Clippings`,
    ///    User's Guides, Welcome, etc.)
    ///  - brand-anchored dictionary detection — stem must contain BOTH an
    ///    Amazon dictionary publisher (Oxford, Duden…) AND the word
    ///    "dictionary"/"diccionario"/"…" to avoid hiding user books like
    ///    "The Devil's Dictionary" by Ambrose Bierce.
    static func isSystemFile(relativePath: String) -> Bool {
        let basename = (relativePath as NSString).lastPathComponent
        let stem = ((basename as NSString).deletingPathExtension).lowercased()

        let amazonStems: Set<String> = [
            "my clippings",
            "kindle user's guide",
            "user's guide",
            "welcome",
            "getting started",
            "quick tour",
        ]
        if amazonStems.contains(stem) { return true }

        // Localized "dictionary" words. These are nouns that are
        // *specifically* used for dictionaries in their languages, so
        // hiding on stem-contains alone is safe — minimal false-positive
        // risk for user books.
        let localizedDictionaryWords = [
            "dicionário", "dictionnaire", "wörterbuch", "diccionario",
        ]
        if localizedDictionaryWords.contains(where: { stem.contains($0) }) {
            return true
        }

        // English "dictionary": require co-occurrence with a known Amazon
        // dictionary publisher so a user's "Devil's Dictionary" stays
        // visible.
        if stem.contains("dictionary") {
            let publishers = ["oxford", "duden", "larousse", "sanseido"]
            if publishers.contains(where: { stem.contains($0) }) {
                return true
            }
        }

        return false
    }
}
