import Foundation

/// Top-level AZW3 writer. Takes a `BookManifest` and emits the
/// PalmDB byte stream that becomes the `.azw3` file on disk.
///
/// The orchestration mirrors leotaku/mobi's `Realize()` and is the
/// load-bearing piece of the spike: every record type developed
/// independently above gets wired together here, and this is where
/// the cross-record numbers (FCIS, FLIS, FDST indices, etc.) get
/// stamped onto the MOBI header just before the null record gets
/// re-serialised.
///
/// Phase 1 (current): single-chapter, single-flow, no images, no CSS,
/// no cover, no compression, ASCII-only safe. See
/// `docs/azw3_phase2.md` for the deferred features.
nonisolated struct AZW3Writer: Sendable {
    let manifest: BookManifest

    init(manifest: BookManifest) {
        self.manifest = manifest
    }

    func encode() -> Data {
        // 1. Render the combined text and figure out chunk + chapter geometry.
        let (text, chunks, chapters) = Markup.chaptersToText(manifest)

        // KF8 record offsets are 32-bit; books over 4 GB of combined
        // text aren't representable. The format also breaks down well
        // before that — Kindle's parser practically caps around the
        // hundreds of MB. This precondition documents the boundary.
        precondition(
            text.count <= UInt32.max,
            "AZW3 combined text exceeds UInt32.max bytes (\(text.count))")

        // 2. Build the null record with EXTH metadata. We mutate it
        //    progressively as we add records and learn their indices,
        //    then replace record 0 at the end.
        let uniqueID = stableID(for: manifest)
        var null = NullRecord(fullName: manifest.title)
        null.mobi.uniqueID = uniqueID
        null.mobi.locale = MicrosoftLocale.code(for: manifest.language)
        null.exth.add(.title, string: manifest.title)
        null.exth.add(.updatedTitle, string: manifest.title)
        for author in manifest.authors {
            null.exth.add(.author, string: author)
        }
        null.exth.add(.language, string: manifest.language)
        null.exth.add(.asin, string: encodeASIN(uniqueID))
        null.exth.add(.docType, string: "EBOK")
        if let date = manifest.publishingDate {
            null.exth.add(.publishingDate, string: iso8601(date))
        }

        // 3. Slice text into 4096-byte records with trailing chapter hints.
        let textRecords = textToRecords(text: text, chapters: chapters)
        null.palmDoc.textRecordCount = UInt16(textRecords.count)
        null.palmDoc.textLength = UInt32(text.count)

        // 4. Start populating the database. Record 0 is a placeholder
        //    NullRecord — we'll replace it with the fully-stamped
        //    version at the end.
        var db = PalmDB.Database(name: manifest.title, date: .now)
        db.records.append(null)

        for textRecord in textRecords {
            db.records.append(textRecord)
        }

        // 5. Padding record after the text section if the last text
        //    record's byte length isn't a multiple of 4. Matches
        //    leotaku's `% 4` quirk (the count is the modulus itself,
        //    not 4-minus-modulus — this is intentional).
        if let lastTextRecord = textRecords.last,
            lastTextRecord.length % 4 != 0
        {
            let padBytes = lastTextRecord.length % 4
            db.records.append(PalmDB.RawRecord(Data(count: padBytes)))
        }

        // First non-text-related record. Used by Kindle to skip past
        // the text/padding section when looking for INDX records.
        null.mobi.firstNonBookIndex = UInt32(db.records.count)

        // 6. Chunk INDX: header + data + cncx (3 records).
        let (chunkData, chunkCNCX) = chunkIndexRecord(chunks: chunks)
        let chunkHeader = chunkHeaderIndexRecord(
            lastPos: text.count, entryCount: chunks.count)
        null.mobi.chunkIndex = UInt32(db.records.count)
        db.records.append(chunkHeader)
        db.records.append(chunkData)
        db.records.append(chunkCNCX)

        // 7. Skeleton INDX: header + data (2 records).
        let skeletonData = skeletonIndexRecord(chunks: chunks)
        let skeletonHeader = skeletonHeaderIndexRecord(entryCount: chunks.count)
        null.mobi.skeletonIndex = UInt32(db.records.count)
        db.records.append(skeletonHeader)
        db.records.append(skeletonData)

        // 8. NCX INDX: header + data + cncx (3 records). Even with one
        //    chapter we need this — leotaku's writer always emits it
        //    and Kindle's parser may rely on its presence.
        let (ncxData, ncxCNCX) = ncxIndexRecord(chapters: chapters)
        let ncxHeader = ncxHeaderIndexRecord(entryCount: chapters.count)
        null.mobi.indxRecordOffset = UInt32(db.records.count)
        db.records.append(ncxHeader)
        db.records.append(ncxData)
        db.records.append(ncxCNCX)

        // 9. Image records — cover first, then body images. The
        //    `firstImageIndex` field on the MOBI header points to the
        //    first image record; EXTH 201 (`coverOffset`) is the
        //    cover's index *within* the image array (always 0 since
        //    cover comes first when present). EXTH 125
        //    (`KF8CountResources`) carries the total image count.
        let images: [ImageData] = (manifest.cover.map { [$0] } ?? []) + manifest.bodyImages
        if !images.isEmpty {
            null.mobi.firstImageIndex = UInt32(db.records.count)
            if manifest.cover != nil {
                null.exth.add(.coverOffset, integer: 0)
                null.exth.add(.hasFakeCover, integer: 0)
                // Newer Kindle firmware uses these to surface covers on
                // the home screen. The URI is 1-based 4-hex-digit; the
                // cover is always the first image record.
                null.exth.add(.kf8CoverURI, string: "kindle:embed:0001")
                null.exth.add(.thumbOffset, integer: 0)
            }
            null.exth.add(.kf8CountResources, integer: UInt32(images.count))
            for image in images {
                db.records.append(PalmDB.RawRecord(image.bytes))
            }
        }

        // 10. FDST: declares the byte ranges of each text "flow" inside
        //     the combined text stream. Entry 0 is the HTML; one entry
        //     per CSS file follows. The skeleton template references
        //     CSS flows as `kindle:flow:NNNN` (1-based decimal).
        let cssLengths = manifest.cssFlows.map { Data($0.utf8).count }
        let totalCSS = cssLengths.reduce(0, +)
        let htmlEnd = text.count - totalCSS
        var fdstEntries: [FDSTRecord.Entry] = [
            .init(start: 0, end: UInt32(htmlEnd))
        ]
        var cssOffset = htmlEnd
        for cssLen in cssLengths {
            fdstEntries.append(
                .init(
                    start: UInt32(cssOffset),
                    end: UInt32(cssOffset + cssLen)
                ))
            cssOffset += cssLen
        }
        null.mobi.fdstEntryCount = UInt32(fdstEntries.count)
        null.mobi.fdstNumberMSB = 0
        null.mobi.fdstNumberLSB = UInt16(db.records.count)
        db.records.append(FDSTRecord(entries: fdstEntries))

        // 11. FLIS — fixed magic record.
        db.records.append(FLISRecord())
        null.mobi.flisRecordCount = 1
        null.mobi.flisRecordNumber = UInt32(db.records.count - 1)

        // 12. FCIS — carries the total text length.
        db.records.append(FCISRecord(textLength: UInt32(text.count)))
        null.mobi.fcisRecordCount = 1
        null.mobi.fcisRecordNumber = UInt32(db.records.count - 1)

        // 13. EOF — the 4-byte terminator.
        db.records.append(EOFRecord())

        // 14. Now that every cross-reference is known, replace record
        //     0 with the fully-stamped null record. Without this,
        //     readers would see UInt32.max defaults for every index
        //     and fail to find anything.
        db.records[0] = null

        return db.encoded()
    }
}

/// Deterministic 32-bit ID. Prefers `<dc:identifier>` from the source
/// EPUB when present (so re-converting the same book gets the same ID
/// across edits to title/author metadata); falls back to FNV-1a of
/// title+authors+language. Drives the MOBI `uniqueID` and pseudo-ASIN.
private nonisolated func stableID(for manifest: BookManifest) -> UInt32 {
    if let id = manifest.identifier, !id.isEmpty {
        return fnv1a(Data(id.utf8))
    }
    var bytes = Data(manifest.title.utf8)
    for author in manifest.authors {
        bytes.append(0)
        bytes.append(Data(author.utf8))
    }
    bytes.append(0)
    bytes.append(Data(manifest.language.utf8))
    return fnv1a(bytes)
}

private nonisolated func fnv1a(_ bytes: Data) -> UInt32 {
    var hash: UInt32 = 0x811C_9DC5
    for byte in bytes {
        hash ^= UInt32(byte)
        hash &*= 0x0100_0193
    }
    return hash
}

private nonisolated func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

/// Pseudo-ASIN: 15-character lowercase hex. UInt32 only fills 8 hex
/// digits, so 7 leading zeros are added. Kindle's parser doesn't
/// validate the value against Amazon's catalogue for sideloaded
/// books, but expects the field to exist and be the right shape.
private nonisolated func encodeASIN(_ id: UInt32) -> String {
    let hex = String(id, radix: 16, uppercase: false)
    if hex.count >= 15 { return hex }
    return String(repeating: "0", count: 15 - hex.count) + hex
}
