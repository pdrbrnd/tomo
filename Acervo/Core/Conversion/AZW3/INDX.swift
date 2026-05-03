import Foundation

/// INDX header — 192 bytes that prefix every INDX record. Each field
/// either has a magic value baked in by leotaku's
/// `NewINDXHeader`, or is set by the writer based on the record's
/// shape (entry count, TAGX presence, etc.).
nonisolated struct INDXHeader: Sendable {
    static let length = 192

    var headerType: UInt32 = 0
    /// 0 = normal, 2 = inflection.
    var indexType: UInt32 = 0
    var idxtStart: UInt32 = 0
    var indexRecordCount: UInt32 = 0
    var indexEntryCount: UInt32 = 0
    var cncxCount: UInt32 = 0
    /// Always set explicitly by `IndexRecord.encoded()` — to 192 when a
    /// TAGX block follows the header, or 0 when there's no TAGX. The
    /// default is 0 because every legitimate emit path overwrites it.
    var tagxOffset: UInt32 = 0

    func encoded() -> Data {
        var w = BinaryWriter(reservingCapacity: Self.length)
        w.writeMagic("INDX")
        w.write(UInt32(Self.length))    // HeaderLength
        w.writeZeros(4)                  // Unknown1
        w.write(headerType)
        w.write(indexType)
        w.write(idxtStart)
        w.write(indexRecordCount)
        w.write(UInt32(65001))           // IndexEncoding (UTF-8)
        w.write(UInt32.max)              // IndexLanguage (none)
        w.write(indexEntryCount)
        w.write(UInt32(0))               // ORDTStart
        w.write(UInt32(0))               // LIGTStart
        w.write(UInt32(0))               // LIGTCount
        w.write(cncxCount)
        w.writeZeros(124)                // Unknown2
        w.write(tagxOffset)
        w.writeZeros(8)                  // Unknown3
        return w.data
    }
}

/// Generic INDX record. KF8 uses these for chunk tables, skeleton
/// tables, and the NCX table-of-contents — each with a different
/// TAGX schema and entry layout.
///
/// The bytes produced are: INDX header → optional TAGX block →
/// concatenated entries → inner padding → IDXT magic → entry offsets
/// → outer padding.
///
/// Padding rules ported verbatim from leotaku/mobi: both the inner
/// (between entries and IDXT) and outer (after IDXT offsets) pads use
/// the raw `length % 4` byte count rather than a true 4-byte
/// alignment. This produces a 4-aligned record only because the
/// fixed-size header parts and the doubled padding combine to even
/// out; it's a quirk of the format, not a general alignment rule.
nonisolated struct IndexRecord: PalmDB.Record {
    /// IDXT entry offsets are uint16 — entries past 65535 bytes from
    /// the start of the record cannot be addressed. None of the AZW3
    /// records we produce come close.
    static let idxtMagicLength = 4
    static let tagxHeaderLength = 12
    static let tagxTagLength = 4

    var type: UInt32 = 0
    var headerType: UInt32 = 0
    var tagxTable: [TAGXTag] = []
    var idxtEntries: [Data] = []
    var subEntryCount: UInt32 = 0
    var cncxCount: UInt32 = 0

    func encoded() -> Data {
        var header = INDXHeader()
        header.indexRecordCount = UInt32(idxtEntries.count)
        header.indexType = type
        header.headerType = headerType
        header.cncxCount = cncxCount
        header.indexEntryCount = subEntryCount

        let tagxBlock = encodedTAGX()
        var offset = INDXHeader.length
        if !tagxTable.isEmpty {
            header.tagxOffset = UInt32(INDXHeader.length)
            offset += tagxBlock.count
        } else {
            header.tagxOffset = 0
        }

        // Walk entries to compute their absolute offsets within the
        // record. The IDXT offset table will use these.
        var idxtOffsets: [UInt16] = []
        idxtOffsets.reserveCapacity(idxtEntries.count)
        var idxtLength = 0
        for entry in idxtEntries {
            idxtOffsets.append(UInt16(offset))
            offset += entry.count
            idxtLength += entry.count
        }
        header.idxtStart = UInt32(offset + idxtLength % 4)

        var w = BinaryWriter(reservingCapacity: lengthNoPadding + lengthNoPadding % 4)
        w.write(header.encoded())
        if !tagxTable.isEmpty {
            w.write(tagxBlock)
        }
        for entry in idxtEntries {
            w.write(entry)
        }
        w.writeZeros(idxtLength % 4)         // Inner pad before IDXT
        w.writeMagic("IDXT")
        for offset in idxtOffsets {
            w.write(offset)
        }
        w.writeZeros(lengthNoPadding % 4)    // Outer pad
        return w.data
    }

    /// Length of the record without the trailing outer padding. Used
    /// internally to compute that padding (matches leotaku's
    /// `LengthNoPadding`).
    var lengthNoPadding: Int {
        let entriesLength = idxtEntries.reduce(0) { $0 + $1.count }
        var length = INDXHeader.length
            + Self.idxtMagicLength
            + idxtEntries.count * 2
            + entriesLength
            + entriesLength % 4              // Inner pad
        if !tagxTable.isEmpty {
            length += Self.tagxHeaderLength + tagxTable.count * Self.tagxTagLength
        }
        return length
    }

    private func encodedTAGX() -> Data {
        guard !tagxTable.isEmpty else { return Data() }
        let total = Self.tagxHeaderLength + tagxTable.count * Self.tagxTagLength
        var w = BinaryWriter(reservingCapacity: total)
        w.writeMagic("TAGX")
        w.write(UInt32(total))               // HeaderLength
        w.write(UInt32(1))                   // ControlByteCount
        for tag in tagxTable {
            w.write(tag.raw)
        }
        return w.data
    }
}
