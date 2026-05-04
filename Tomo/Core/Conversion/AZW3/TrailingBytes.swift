import Foundation

/// Trailing bytes appended to every text record. Two pieces of data
/// are encoded here:
///
///   1. Multibyte overlap — how many UTF-8 continuation bytes from this
///      record actually belong to the next one. The MOBI header's
///      `extraRecordDataFlags` bit 0 enables this.
///   2. Strand index data — a hint about which chapter (or chapters)
///      the record belongs to. Bit 1 of `extraRecordDataFlags` enables
///      this.
///
/// We always set both bits, so every text record carries trailing
/// bytes for both. After the payload is built, the *byte length* of
/// the trailing data is appended as a VWI; the reader uses it to walk
/// backward from the end of the record to find where the trail starts.
///
/// Limitation: `multibyte` is always 0 in this port. Kindle uses it to
/// reattach UTF-8 sequences that get sliced across record boundaries.
/// For ASCII books (Phase 1's Frankenstein target) this is correct.
/// For UTF-8 with non-ASCII characters, a future iteration must
/// compute the actual trailing-continuation-byte count.

/// One strand of indexing data — a chapter reference plus a few flags.
nonisolated struct StrandData: Sendable, Equatable {
    var index: Int
    var firstOfNotFirstStrand: Bool = false
    /// Reverse-engineered "TBS type" — 8 in our usage. Zero would
    /// suppress the type byte from the encoded output.
    var tbsType: Int = 0
    var numSiblings: UInt8 = 0
    var doesSpan: Bool = false

    func encoded() -> Data {
        var value = index << 3
        if doesSpan { value |= 0b0001 }
        if tbsType != 0 { value |= 0b0010 }
        if numSiblings > 1 { value |= 0b0100 }
        if firstOfNotFirstStrand { value |= 0b1000 }

        var output = encodeVWI(value)
        if tbsType != 0 { output.append(encodeVWI(tbsType)) }
        if numSiblings > 1 { output.append(numSiblings) }
        if doesSpan { output.append(encodeVWI(0)) }
        return output
    }
}

/// The bytes emitted at the end of one text record, before the
/// length-suffix VWI added by `encoded()`.
nonisolated struct TrailingData: Sendable, Equatable {
    var multibyte: UInt8 = 0
    var strand: StrandData? = nil

    func encoded() -> Data {
        var payload = Data([multibyte])
        if let strand {
            payload.append(strand.encoded())
        }
        // The length suffix lets the parser walk back from the end of
        // the record to the start of the trail without needing the
        // trail size declared upfront.
        var output = payload
        output.append(encodeVWI(payload.count))
        return output
    }
}

/// Number of bytes at the start of the *next* record that belong to
/// a UTF-8 multibyte sequence beginning in *this* record. Kindle uses
/// this to reattach a sequence that got sliced when text was sharded
/// at the 4096-byte boundary.
///
/// Returns 0 for ASCII-only records, records ending on a complete
/// multibyte sequence, or empty records. Returns 1–3 when the record
/// ends mid-sequence, telling the reader how many continuation bytes
/// from the next record complete it.
///
/// References: MobileRead Wiki MOBI Extra Data Flags; KindleUnpack
/// `mobi_header.py` parser side reads this as `(last_byte & 3) + 1`.
nonisolated func multibyteOverlap(in record: Data) -> UInt8 {
    let bytes = Array(record)
    guard !bytes.isEmpty else { return 0 }

    // Walk backwards over UTF-8 continuation bytes (0x80-0xBF) until
    // we hit either the start of the record or a non-continuation
    // byte (which is either the sequence starter or ASCII).
    var i = bytes.count - 1
    while i > 0, bytes[i] >= 0x80, bytes[i] < 0xC0 {
        i -= 1
    }

    let starter = bytes[i]
    let expected: Int
    switch starter {
    case 0x00...0x7F: return 0  // ASCII or end of complete sequence
    case 0x80...0xBF: return 0  // Stuck on continuation byte; broken UTF-8
    case 0xC0...0xDF: expected = 2
    case 0xE0...0xEF: expected = 3
    case 0xF0...0xF7: expected = 4
    default: return 0  // Invalid UTF-8 starter
    }

    let bytesInThisRecord = bytes.count - i
    if bytesInThisRecord >= expected {
        return 0  // Sequence completed inside this record
    }
    return UInt8(expected - bytesInThisRecord)
}

/// Builds `TrailingData` for arbitrary `[from, to)` byte ranges by
/// walking the chapter table. The first chapter that wholly contains
/// the range owns the strand; otherwise we record the first chapter
/// touching the range and accumulate sibling counts as further
/// chapters touch it.
nonisolated struct TrailProvider: Sendable {
    let chapters: [ChapterInfo]

    init(chapters: [ChapterInfo]) {
        self.chapters = chapters
    }

    func get(from: Int, to: Int) -> TrailingData {
        var data = TrailingData(multibyte: 0)
        for (i, chapter) in chapters.enumerated() {
            let end = chapter.start + chapter.length

            // Case 1: chapter wholly contains the record range.
            if chapter.start <= from && end >= to {
                let atExactBoundary = chapter.start == from || end == to
                data.strand = StrandData(
                    index: i,
                    tbsType: 8,
                    doesSpan: !atExactBoundary
                )
                return data
            }

            // Case 2: chapter starts or ends within the record range.
            let chapterStartsHere = from <= chapter.start && chapter.start <= to
            let chapterEndsHere = from <= end && end <= to
            if chapterStartsHere || chapterEndsHere {
                if data.strand == nil {
                    data.strand = StrandData(index: i, tbsType: 8)
                }
                data.strand?.numSiblings += 1
            }
        }
        return data
    }
}
