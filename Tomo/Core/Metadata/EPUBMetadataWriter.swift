import Foundation
import ZIPFoundation
import os

/// Projects a `Book`'s edited metadata (title / authors / language / series)
/// onto a *copy* of an EPUB, for devices that read the EPUB's embedded
/// `content.opf` directly (Kobo) rather than going through Tomo's manifest
/// builder (Kindle).
///
/// The library file is never touched — the sidecar stays the source of truth;
/// this only rewrites the delivered copy at send time. Mirrors how the Kindle
/// path projects covers/metadata into the AZW3 without mutating the library.
///
/// Best-effort by design: if the EPUB can't be parsed (DRM, malformed) or the
/// rewrite fails for any reason, callers fall back to sending the original
/// untouched — exactly today's behaviour. We never break delivery to correct
/// metadata.
nonisolated enum EPUBMetadataWriter {

    /// Dublin Core namespace — used when constructing fresh `<dc:*>` elements.
    private static let dcURI = "http://purl.org/dc/elements/1.1/"
    private static let opfURI = "http://www.idpf.org/2007/opf"

    /// If `book`'s title/authors/language/series differ from what's embedded
    /// in the EPUB at `source`, writes a metadata-corrected copy into
    /// `scratchDir` and returns its URL. Returns `nil` when nothing differs
    /// (caller should send the original) or when anything goes wrong
    /// (fallback to original).
    ///
    /// Only the differing fields are rewritten, so an EPUB whose authors the
    /// user never touched keeps its original `<dc:creator>` nodes intact —
    /// including any `opf:file-as` the device sorts by. Authors that *did*
    /// change are rewritten as plain display names (no `file-as` synthesis).
    static func metadataCorrectedCopy(
        of source: URL,
        for book: Book,
        into scratchDir: URL
    ) -> URL? {
        guard let epub = try? EPUBArchive.open(source) else {
            // DRM, malformed, unreadable, evicted — send the original as-is.
            return nil
        }

        let titleDiffers = book.title != (epub.opf.title ?? "")
        let authorsDiffer = book.authors != epub.opf.authors
        // Treat an absent `<dc:language>` as "und" so a book left at "und"
        // doesn't trigger a needless rewrite.
        let langDiffers = book.locale != (epub.opf.language ?? "und")
        // An empty list means the user has no series for this book, so the
        // EPUB's gets removed. Except before `MetadataMigration` has run:
        // then Tomo simply hasn't read the series yet, and the EPUB's stays.
        // Both sides are compared in written form, so a position the writer
        // can't carry (`2a`) doesn't force a rewrite on every send.
        let epub3 = epub.opf.version?.hasPrefix("3") ?? false
        let bookSeries = writableSeries(book.series, epub3: epub3)
        let seriesKnown = !MetadataMigration.needsMigration(book)
        let seriesDiffers =
            seriesKnown && bookSeries != writableSeries(epub.opf.series, epub3: epub3)

        guard titleDiffers || authorsDiffer || langDiffers || seriesDiffers else { return nil }

        guard let opfData = epub.data(at: epub.opfPath) else { return nil }

        guard
            let newOPFData = rewriteOPF(
                opfData,
                title: titleDiffers ? book.title : nil,
                authors: authorsDiffer ? book.authors : nil,
                language: langDiffers ? book.locale : nil,
                series: seriesDiffers ? bookSeries : nil,
                epub3: epub3
            )
        else { return nil }

        let dest = scratchDir.appending(component: source.lastPathComponent)
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path(percentEncoded: false)) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: source, to: dest)

            let archive = try Archive(url: dest, accessMode: .update)
            guard let entry = archive[epub.opfPath] else { return nil }
            try archive.remove(entry)
            // Store (no compression) — only `mimetype` must be stored in an
            // EPUB, but storing the OPF too is valid and keeps this simple.
            // `remove` preserves the order of surviving entries, so the
            // first-entry `mimetype` stays put; this re-added OPF lands last.
            try archive.addEntry(
                with: epub.opfPath,
                type: .file,
                uncompressedSize: Int64(newOPFData.count),
                compressionMethod: .none,
                provider: { position, size in
                    let start = Int(position)
                    let end = min(start + size, newOPFData.count)
                    guard start < end else { return Data() }
                    return newOPFData.subdata(in: start..<end)
                }
            )
            return dest
        } catch {
            metadataLogger.warning(
                "EPUB metadata rewrite failed, sending original: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Returns the OPF XML with the given fields overwritten, or `nil` if the
    /// XML can't be parsed or re-serialised. A `nil` field is left untouched.
    private static func rewriteOPF(
        _ data: Data,
        title: String?,
        authors: [String]?,
        language: String?,
        series: [BookSeries]?,
        epub3: Bool
    ) -> Data? {
        guard let doc = try? XMLDocument(data: data) else { return nil }

        guard
            let metadata = (try? doc.nodes(forXPath: "//*[local-name()='metadata']"))?
                .first as? XMLElement
        else { return nil }

        if let title {
            setOrCreate(in: metadata, localName: "title", qualifiedName: "dc:title", value: title)
        }

        if let language {
            setOrCreate(in: metadata, localName: "language", qualifiedName: "dc:language", value: language)
        }

        if let authors {
            // Drop every existing creator (and its stale file-as/role) and
            // re-add the accepted display names. This is the documented trade
            // for not carrying structured author data.
            for node in (try? doc.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='creator']")) ?? [] {
                node.detach()
            }
            for author in authors {
                let element = XMLElement(name: "dc:creator", uri: dcURI)
                element.stringValue = author
                metadata.addChild(element)
            }
        }

        if let series {
            rewriteSeries(series, in: metadata, epub3: epub3)
        }

        return doc.xmlData()
    }

    /// Series exactly as `rewriteSeries` would write them: empty names
    /// dropped, positions trimmed and kept only when numeric, and a single
    /// series for EPUB 2 (Calibre's tags hold one).
    private static func writableSeries(_ memberships: [BookSeries], epub3: Bool) -> [BookSeries] {
        let writable = memberships.compactMap { membership -> BookSeries? in
            let name = membership.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let position = membership.position?.trimmingCharacters(in: .whitespacesAndNewlines)
            return BookSeries(
                name: name,
                position: position.flatMap { BookSeries.isStandardPosition($0) ? $0 : nil }
            )
        }
        return epub3 ? writable : Array(writable.prefix(1))
    }

    /// Replaces only series collections, leaving other EPUB collection
    /// memberships (for example a set or publisher collection) intact.
    private static func rewriteSeries(
        _ memberships: [BookSeries],
        in metadata: XMLElement,
        epub3: Bool
    ) {
        let metaElements = metadata.children?.compactMap { $0 as? XMLElement } ?? []
        var seriesIDs: Set<String> = []
        for element in metaElements where
            element.attribute(forName: "property")?.stringValue == "belongs-to-collection"
        {
            guard let id = element.attribute(forName: "id")?.stringValue else { continue }
            let isSeries = metaElements.contains {
                guard $0.attribute(forName: "refines")?.stringValue == "#\(id)",
                    $0.attribute(forName: "property")?.stringValue == "collection-type",
                    let value = $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                else { return false }
                return value.caseInsensitiveCompare("series") == .orderedSame
            }
            if isSeries { seriesIDs.insert(id) }
        }

        for element in metaElements {
            if let id = element.attribute(forName: "id")?.stringValue, seriesIDs.contains(id) {
                element.detach()
                continue
            }
            if let refines = element.attribute(forName: "refines")?.stringValue,
                seriesIDs.contains(String(refines.dropFirst()))
            {
                element.detach()
                continue
            }
            let legacyName = element.attribute(forName: "name")?.stringValue
            if legacyName == "calibre:series" || legacyName == "calibre:series_index" {
                element.detach()
            }
        }

        for (index, membership) in memberships.enumerated() {
            if epub3 {
                let id = "tomo-series-\(index)-\(UUID().uuidString.lowercased())"
                let collection = XMLElement(name: "meta", uri: opfURI)
                addAttribute(to: collection, name: "property", value: "belongs-to-collection")
                addAttribute(to: collection, name: "id", value: id)
                collection.stringValue = membership.name
                metadata.addChild(collection)

                let type = XMLElement(name: "meta", uri: opfURI)
                addAttribute(to: type, name: "refines", value: "#\(id)")
                addAttribute(to: type, name: "property", value: "collection-type")
                type.stringValue = "series"
                metadata.addChild(type)

                if let position = membership.position {
                    let groupPosition = XMLElement(name: "meta", uri: opfURI)
                    addAttribute(to: groupPosition, name: "refines", value: "#\(id)")
                    addAttribute(to: groupPosition, name: "property", value: "group-position")
                    groupPosition.stringValue = position
                    metadata.addChild(groupPosition)
                }
            } else {
                // EPUB 2 has no collection vocabulary; `writableSeries` keeps
                // only the primary series, written as Calibre's widely
                // understood tags.
                let legacySeries = XMLElement(name: "meta", uri: opfURI)
                addAttribute(to: legacySeries, name: "name", value: "calibre:series")
                addAttribute(to: legacySeries, name: "content", value: membership.name)
                metadata.addChild(legacySeries)

                if let position = membership.position {
                    let legacyPosition = XMLElement(name: "meta", uri: opfURI)
                    addAttribute(to: legacyPosition, name: "name", value: "calibre:series_index")
                    addAttribute(to: legacyPosition, name: "content", value: position)
                    metadata.addChild(legacyPosition)
                }
            }
        }
    }

    private static func addAttribute(to element: XMLElement, name: String, value: String) {
        if let attribute = XMLNode.attribute(withName: name, stringValue: value) as? XMLNode {
            element.addAttribute(attribute)
        }
    }

    /// Sets the first matching child's text, or creates the element if absent.
    private static func setOrCreate(
        in metadata: XMLElement,
        localName: String,
        qualifiedName: String,
        value: String
    ) {
        let existing =
            (try? metadata.nodes(forXPath: "./*[local-name()='\(localName)']"))?
            .first as? XMLElement
        if let existing {
            existing.stringValue = value
        } else {
            let element = XMLElement(name: qualifiedName, uri: dcURI)
            element.stringValue = value
            metadata.addChild(element)
        }
    }
}
