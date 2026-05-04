import Foundation

/// Per-chunk geometry recorded in the chunk and skeleton INDX records.
/// `pre*` describe the skeleton portion (HTML scaffolding around the
/// chunk content); `content*` describe the chunk's own text bytes
/// inside the combined text stream.
nonisolated struct ChunkInfo: Sendable, Equatable {
    let preStart: Int
    let preLength: Int
    let contentStart: Int
    let contentLength: Int
}

/// Per-chapter info for the NCX (table-of-contents) index.
nonisolated struct ChapterInfo: Sendable, Equatable {
    let title: String
    let start: Int
    let length: Int
}

// MARK: - Header records

/// NCX header INDX record. Sits before the data NCX record and the
/// CNCX, declaring entry count and the TAGX schema. Type=2 marks it
/// as a header record; the data record uses type=0 + headerType=1.
nonisolated func ncxHeaderIndexRecord(entryCount: Int) -> IndexRecord {
    let label = encodeINDXString(String(format: "%03d", entryCount - 1))
    var entry = label
    entry.append(uint16BigEndian(UInt16(entryCount)))
    entry.append(Data(count: 3))    // Trailing zero pad inside entry
    return IndexRecord(
        type: 2,
        tagxTable: TAGXTable.ncxSingle,
        idxtEntries: [entry],
        subEntryCount: UInt32(entryCount),
        cncxCount: 1
    )
}

nonisolated func skeletonHeaderIndexRecord(entryCount: Int) -> IndexRecord {
    let label = encodeINDXString("SKEL" + String(format: "%010d", entryCount - 1))
    var entry = label
    entry.append(uint16BigEndian(UInt16(entryCount)))
    entry.append(Data(count: 3))
    return IndexRecord(
        type: 2,
        tagxTable: TAGXTable.skeleton,
        idxtEntries: [entry],
        subEntryCount: UInt32(entryCount)
    )
}

nonisolated func chunkHeaderIndexRecord(lastPos: Int, entryCount: Int) -> IndexRecord {
    let label = encodeINDXString(String(format: "%010d", lastPos))
    var entry = label
    entry.append(uint16BigEndian(UInt16(entryCount)))
    entry.append(Data(count: 3))
    return IndexRecord(
        type: 2,
        tagxTable: TAGXTable.chunk,
        idxtEntries: [entry],
        subEntryCount: UInt32(entryCount),
        cncxCount: 1
    )
}

// MARK: - Data records

/// Builds the NCX data record + its accompanying CNCX string table.
/// One entry per chapter: position, length, name offset (into CNCX),
/// depth level (currently always 0 for flat chapter lists).
///
/// Note: leotaku/mobi computes the control byte from `TAGXTableChunk`
/// here, not `TAGXTableNCXSingle`. Both produce 15 (the four
/// single-value tags happen to share the same bit layout), so the
/// emitted bytes are identical. We use `ncxSingle` for the
/// semantically-correct tag table; the comment exists so anyone
/// diffing against the Go reference doesn't think this is wrong.
nonisolated func ncxIndexRecord(chapters: [ChapterInfo]) -> (IndexRecord, CNCXRecord) {
    var idxtEntries: [Data] = []
    var cncxEntries: [Data] = []
    var cncxOffset = 0
    let controlByte = calculateControlByte(TAGXTable.ncxSingle)

    for chapter in chapters {
        let cncx = encodeCNCXString(chapter.title)
        cncxEntries.append(cncx)

        let label = encodeINDXString(String(format: "%03x", chapter.start))
        var entry = label
        entry.append(controlByte)
        entry.append(encodeVWI(chapter.start))    // Record offset
        entry.append(encodeVWI(chapter.length))   // Record length
        entry.append(encodeVWI(cncxOffset))       // Title offset in CNCX
        entry.append(encodeVWI(0))                // Depth level (flat)
        idxtEntries.append(entry)

        cncxOffset += cncx.count
    }

    return (
        IndexRecord(
            type: 0,
            headerType: 1,
            idxtEntries: idxtEntries
        ),
        CNCXRecord(entries: cncxEntries)
    )
}

/// Builds the skeleton data record. One entry per chunk: chunk count
/// (always 1 in our flat layout) and the geometry of the skeleton's
/// HTML scaffolding around the chunk content.
nonisolated func skeletonIndexRecord(chunks: [ChunkInfo]) -> IndexRecord {
    var idxtEntries: [Data] = []
    let controlByte = calculateControlByte(TAGXTable.skeleton)

    for (i, chunk) in chunks.enumerated() {
        let label = encodeINDXString("SKEL" + String(format: "%010d", i))
        var entry = label
        entry.append(controlByte)
        entry.append(encodeVWI(1))                  // Chunk count for this skel
        entry.append(encodeVWI(1))                  // (paired count)
        entry.append(encodeVWI(chunk.preStart))     // Skel byte start
        entry.append(encodeVWI(chunk.preLength))    // Skel byte length
        idxtEntries.append(entry)
    }

    return IndexRecord(
        type: 0,
        headerType: 1,
        idxtEntries: idxtEntries
    )
}

/// Builds the chunk data record + its accompanying CNCX string table.
/// One entry per chunk: a `kindle:embed`-style aid reference into the
/// CNCX, the chunk's file/sequence numbers, and its content geometry.
nonisolated func chunkIndexRecord(chunks: [ChunkInfo]) -> (IndexRecord, CNCXRecord) {
    var idxtEntries: [Data] = []
    var cncxEntries: [Data] = []
    var cncxOffset = 0
    let controlByte = calculateControlByte(TAGXTable.chunk)

    for (i, chunk) in chunks.enumerated() {
        let cncxString = "P-//*[@aid='\(to32(i))']"
        let cncx = encodeCNCXString(cncxString)
        cncxEntries.append(cncx)

        let label = encodeINDXString(String(format: "%010d", chunk.contentStart))
        var entry = label
        entry.append(controlByte)
        entry.append(encodeVWI(cncxOffset))         // CNCX offset
        entry.append(encodeVWI(i))                  // File number
        entry.append(encodeVWI(i))                  // Sequence number
        entry.append(encodeVWI(0))                  // Geometry start
        entry.append(encodeVWI(chunk.contentLength)) // Geometry length
        idxtEntries.append(entry)

        cncxOffset += cncx.count
    }

    return (
        IndexRecord(
            type: 0,
            headerType: 1,
            idxtEntries: idxtEntries
        ),
        CNCXRecord(entries: cncxEntries)
    )
}

// MARK: - Helpers

/// Base-32 string with leotaku's formatting: uppercase digits, padded
/// to 4 characters with leading zeros. Used to build the `aid`
/// attributes in chunk CNCX entries.
nonisolated func to32(_ value: Int) -> String {
    precondition(value >= 0, "to32 requires non-negative input")
    let digits = String(value, radix: 32, uppercase: true)
    if digits.count >= 4 { return digits }
    return String(repeating: "0", count: 4 - digits.count) + digits
}

private nonisolated func uint16BigEndian(_ value: UInt16) -> Data {
    var w = BinaryWriter(reservingCapacity: 2)
    w.write(value)
    return w.data
}
