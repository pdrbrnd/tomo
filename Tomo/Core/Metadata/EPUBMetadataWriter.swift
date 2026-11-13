import Foundation
import ZIPFoundation
import os

/// Projects a `Book`'s edited metadata (title / authors / language / series
/// / cover) onto a *copy* of an EPUB, for devices that read the EPUB's embedded
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

    /// If `book`'s title/authors/language/series/cover differ from what's
    /// embedded in the EPUB at `source`, writes a metadata-corrected copy into
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

        let cover = coverChange(for: book, in: epub)

        let metadataDiffers = titleDiffers || authorsDiffer || langDiffers || seriesDiffers
        guard metadataDiffers || cover != nil else { return nil }

        // A replaced cover keeps its manifest entry, so the OPF only changes
        // when a field differs or the cover is a new item.
        var newOPFData: Data?
        if metadataDiffers || cover?.addedHref != nil {
            guard let opfData = epub.data(at: epub.opfPath),
                let rewritten = rewriteOPF(
                    opfData,
                    title: titleDiffers ? book.title : nil,
                    authors: authorsDiffer ? book.authors : nil,
                    language: langDiffers ? book.locale : nil,
                    series: seriesDiffers ? bookSeries : nil,
                    addedCoverHref: cover?.addedHref,
                    epub3: epub3
                )
            else { return nil }
            newOPFData = rewritten
        }

        let dest = scratchDir.appending(component: source.lastPathComponent)
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path(percentEncoded: false)) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: source, to: dest)

            let archive = try Archive(url: dest, accessMode: .update)
            if let newOPFData {
                try replaceEntry(in: archive, at: epub.opfPath, with: newOPFData)
            }
            switch cover {
            case .replace(let path, let data):
                try replaceEntry(in: archive, at: path, with: data)
            case .add(let href, let data):
                let path = epub.opfDir.isEmpty ? href : "\(epub.opfDir)/\(href)"
                try replaceEntry(in: archive, at: path, with: data)
            case nil:
                break
            }
            return dest
        } catch {
            metadataLogger.warning(
                "EPUB metadata rewrite failed, sending original: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// How the user's cover reaches the copy.
    private enum CoverChange {
        /// Overwrite the EPUB's cover image entry in place, re-encoded to its
        /// declared type, so a cover page that shows the image updates too.
        case replace(path: String, data: Data)
        /// The EPUB has no cover Tomo can overwrite: add a JPEG (href
        /// relative to the OPF) and point the cover metadata at it.
        case add(href: String, data: Data)

        var addedHref: String? {
            if case .add(let href, _) = self { return href }
            return nil
        }
    }

    private static let addedCoverID = "tomo-cover"
    private static let addedCoverHref = "tomo-cover.jpg"

    /// The cover change needed for the copy to show the book's cover, or nil
    /// when the EPUB already carries it. Import stores the EPUB's cover bytes
    /// verbatim, so a byte-equal file means the user hasn't changed it.
    ///
    /// A removed cover (no `coverURL`) leaves the EPUB's own in place:
    /// stripping it cleanly would mean editing the cover page as well.
    private static func coverChange(for book: Book, in epub: EPUBArchive) -> CoverChange? {
        guard let coverURL = book.coverURL, let userCover = try? Data(contentsOf: coverURL) else {
            return nil
        }
        let userMime = mimeFromExtension(coverURL.path)

        if let item = epub.opf.coverItem {
            let path = EPUBArchive.resolvePath(item.href, baseDir: epub.opfDir)
            if let existing = epub.data(at: path) {
                if existing == userCover { return nil }
                let mime = item.mediaType.isEmpty ? mimeFromExtension(item.href) : item.mediaType
                if let data = encodeCover(userCover, from: userMime, to: mime) {
                    return .replace(path: path, data: data)
                }
            }
        }

        guard let jpeg = encodeCover(userCover, from: userMime, to: "image/jpeg") else {
            metadataLogger.warning("cover could not be encoded for EPUB; sending EPUB's own")
            return nil
        }
        return .add(href: addedCoverHref, data: jpeg)
    }

    /// `bytes` as `targetMime`, passed through when already that type. Only
    /// JPEG and PNG targets; anything else (SVG, GIF) returns nil.
    private static func encodeCover(_ bytes: Data, from sourceMime: String, to targetMime: String) -> Data? {
        if sourceMime == targetMime { return bytes }
        switch targetMime {
        case "image/jpeg": return CoverRasterizer.reencodeToJPEG(bytes)
        case "image/png": return CoverRasterizer.reencodeToPNG(bytes)
        default: return nil
        }
    }

    /// Writes `data` at `path`, replacing any existing entry. Stored (no
    /// compression) — only `mimetype` must be stored in an EPUB, but storing
    /// more is valid and images don't compress anyway. `remove` preserves
    /// the order of surviving entries, so the first-entry `mimetype` stays
    /// put; the written entry lands last.
    private static func replaceEntry(in archive: Archive, at path: String, with data: Data) throws {
        if let entry = archive[path] {
            try archive.remove(entry)
        }
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .none,
            provider: { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                guard start < end else { return Data() }
                return data.subdata(in: start..<end)
            }
        )
    }

    /// Returns the OPF XML with the given fields overwritten, or `nil` if the
    /// XML can't be parsed or re-serialised. A `nil` field is left untouched.
    private static func rewriteOPF(
        _ data: Data,
        title: String?,
        authors: [String]?,
        language: String?,
        series: [BookSeries]?,
        addedCoverHref: String?,
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

        if let addedCoverHref {
            guard
                let manifest = (try? doc.nodes(forXPath: "//*[local-name()='manifest']"))?
                    .first as? XMLElement
            else { return nil }
            addCover(href: addedCoverHref, metadata: metadata, manifest: manifest, epub3: epub3)
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

    /// Points the cover metadata at a new JPEG manifest item, dropping
    /// whatever cover declaration was there (it named an image Tomo couldn't
    /// overwrite, or one missing from the archive).
    private static func addCover(
        href: String,
        metadata: XMLElement,
        manifest: XMLElement,
        epub3: Bool
    ) {
        for element in metadata.children?.compactMap({ $0 as? XMLElement }) ?? []
        where element.attribute(forName: "name")?.stringValue == "cover" {
            element.detach()
        }
        for item in manifest.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            guard let properties = item.attribute(forName: "properties")?.stringValue else { continue }
            let kept = properties.split(separator: " ").filter { $0 != "cover-image" }
            if kept.isEmpty {
                item.removeAttribute(forName: "properties")
            } else {
                item.attribute(forName: "properties")?.stringValue = kept.joined(separator: " ")
            }
        }

        let item = XMLElement(name: "item", uri: opfURI)
        addAttribute(to: item, name: "id", value: addedCoverID)
        addAttribute(to: item, name: "href", value: href)
        addAttribute(to: item, name: "media-type", value: "image/jpeg")
        if epub3 {
            addAttribute(to: item, name: "properties", value: "cover-image")
        }
        manifest.addChild(item)

        // EPUB 2's cover declaration; EPUB 3 still allows it, and readers
        // that predate `cover-image` (Kobo's included) look for it.
        let meta = XMLElement(name: "meta", uri: opfURI)
        addAttribute(to: meta, name: "name", value: "cover")
        addAttribute(to: meta, name: "content", value: addedCoverID)
        metadata.addChild(meta)
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
