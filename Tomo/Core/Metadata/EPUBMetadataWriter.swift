import Foundation
import ZIPFoundation
import os

/// Projects a `Book`'s edited metadata (title / authors / language) onto a
/// *copy* of an EPUB, for devices that read the EPUB's embedded `content.opf`
/// directly (Kobo) rather than going through Tomo's manifest builder (Kindle).
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

    /// If `book`'s title/authors/language differ from what's embedded in the
    /// EPUB at `source`, writes a metadata-corrected copy into `scratchDir`
    /// and returns its URL. Returns `nil` when nothing differs (caller should
    /// send the original) or when anything goes wrong (fallback to original).
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

        guard titleDiffers || authorsDiffer || langDiffers else { return nil }

        guard let opfData = epub.data(at: epub.opfPath) else { return nil }

        guard
            let newOPFData = rewriteOPF(
                opfData,
                title: titleDiffers ? book.title : nil,
                authors: authorsDiffer ? book.authors : nil,
                language: langDiffers ? book.locale : nil
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
        language: String?
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

        return doc.xmlData()
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
