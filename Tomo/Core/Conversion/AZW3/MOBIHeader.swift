import Foundation

/// PalmDoc header — the first 16 bytes of the Null record (record 0).
/// It tells the reader how text records are compressed and laid out.
/// Layout per the MobileRead Wiki:
///
///   offset  size  field
///   0       2     Compression  (1=none, 2=PalmDOC, 17480=HUFF/CDIC)
///   2       2     unused
///   4       4     TextLength   (sum of decompressed text record sizes)
///   8       2     TextRecordCount
///   10      2     RecordSize   (typically 4096)
///   12      2     Encryption   (0=none, 1=Mobipocket, 2=DRM)
///   14      2     unknown
nonisolated struct PalmDocHeader: Sendable {
    static let length = 16

    /// 1 = no compression. Phase 1 ships uncompressed; PalmDoc LZ77
    /// compression (value 2) is a Phase 2 optimisation.
    var compression: UInt16 = 1
    var textLength: UInt32 = 0
    var textRecordCount: UInt16 = 0
    /// Decompressed size of each text record. 4096 (`0x1000`) is the
    /// universal default — Kindle firmware expects it.
    var recordSize: UInt16 = 0x1000
    var encryption: UInt16 = 0

    func encoded() -> Data {
        var w = BinaryWriter(reservingCapacity: Self.length)
        w.write(compression)
        w.write(UInt16(0))  // unused
        w.write(textLength)
        w.write(textRecordCount)
        w.write(recordSize)
        w.write(encryption)
        w.write(UInt16(0))  // unknown
        return w.data
    }
}

/// MOBI / KF8 header — 264 bytes when emitting KF8, which is the only
/// variant Tomo produces. Sits immediately after the 16-byte PalmDoc
/// header inside the Null record. Default values match leotaku/mobi's
/// `NewKF8Header()`; many fields are constants documented by the spec
/// or the reverse-engineering community as "leave at this value or
/// readers misbehave."
///
/// Reference layout: https://wiki.mobileread.com/wiki/MOBI
nonisolated struct KF8Header: Sendable {
    /// 232-byte common MOBI header + 32-byte KF8 extension.
    static let length = 264

    // MARK: - Common MOBI fields (232 bytes)

    /// Reported header length. KF8 uses 264 (`0xE8 + 32`); MOBI 6 used
    /// 232. We always emit KF8.
    var headerLength: UInt32 = UInt32(KF8Header.length)
    /// 2 = book. Other values are reserved for newspapers, magazines, etc.
    var mobiType: UInt32 = 2
    /// 65001 = UTF-8.
    var textEncoding: UInt32 = 65001
    var uniqueID: UInt32 = 0
    /// 8 marks this as KF8. 6 would mean MOBI 6.
    var fileVersion: UInt32 = 8

    /// Index fields that Tomo doesn't populate. Spec convention is
    /// `UInt32.max` ("not present") for unused index slots.
    var orthographicIndex: UInt32 = .max
    var inflectionIndex: UInt32 = .max
    var indexNames: UInt32 = .max
    var indexKeys: UInt32 = .max
    var extraIndex0: UInt32 = .max
    var extraIndex1: UInt32 = .max
    var extraIndex2: UInt32 = .max
    var extraIndex3: UInt32 = .max
    var extraIndex4: UInt32 = .max
    var extraIndex5: UInt32 = .max

    var firstNonBookIndex: UInt32 = 0
    /// Set by `NullRecord.encoded()` based on actual EXTH section length.
    var fullNameOffset: UInt32 = 0
    /// Set by `NullRecord.encoded()` based on actual name byte count.
    var fullNameLength: UInt32 = 0

    /// 0 means NEUTRAL-NEUTRAL.
    var locale: UInt32 = 0
    var inputLanguage: UInt32 = 0
    var outputLanguage: UInt32 = 0

    /// 8 marks the minimum reader version capable of opening the book.
    var minVersion: UInt32 = 8
    /// `UInt32.max` = no images.
    var firstImageIndex: UInt32 = .max
    var huffmanRecordOffset: UInt32 = 0
    var huffmanRecordCount: UInt32 = 0
    var huffmanTableOffset: UInt32 = 0
    var huffmanTableLength: UInt32 = 0

    /// Bitmask `0b1010000` (= 80) is what Calibre writes; copying it
    /// keeps Kindle's parser happy. Bit meanings are not fully
    /// documented; reverse-engineered as "EXTH is present, KF8-style."
    var exthFlags: UInt32 = 0b1010000

    /// 32 bytes of zeros. Spec leaves this empty.
    var unknown1: Data = Data(count: 32)

    /// `UInt32.max` for both = no DRM.
    var drmOffset: UInt32 = .max
    var drmCount: UInt32 = .max
    var drmSize: UInt32 = 0
    var drmFlags: UInt32 = 0

    /// 12 bytes of zeros.
    var unknown2: Data = Data(count: 12)

    /// In KF8 these two UInt16s are FDSTNumber high/low halves. KF8
    /// default of `UInt16.max` for both = "FDST number not yet assigned"
    /// (the AZW3 writer fills them in once the FDST record's index is
    /// known).
    var fdstNumberMSB: UInt16 = .max
    var fdstNumberLSB: UInt16 = .max

    /// In KF8 mode this carries the FDST entry count, which our writer
    /// sets to 0 in `NewKF8Header()` — leaving it at 0 here matches.
    var fdstEntryCount: UInt32 = 0

    var fcisRecordNumber: UInt32 = 0
    var fcisRecordCount: UInt32 = 0
    var flisRecordNumber: UInt32 = 0
    var flisRecordCount: UInt32 = 0

    var unknown4: UInt64 = 0
    var unknown5: UInt32 = .max
    var firstCompilationSectionCount: UInt32 = 0
    var compilationSectionCount: UInt32 = .max
    var unknown6: UInt32 = .max

    /// `0b11` enables the two extra-record-data flags Calibre uses.
    /// Required for Kindle to find the multibyte / trailing-byte hints
    /// at the end of each text record.
    var extraRecordDataFlags: UInt32 = 0b11

    var indxRecordOffset: UInt32 = .max

    // MARK: - KF8 extension (32 bytes)

    /// Index of the chunk-table INDX record, or `UInt32.max` if not yet
    /// assigned. The AZW3 writer fills these in once the records are
    /// laid out.
    var chunkIndex: UInt32 = .max
    var skeletonIndex: UInt32 = .max
    var huffmanTableIndex: UInt32 = .max
    var guideIndex: UInt32 = .max
    /// 16 bytes of zeros.
    var kf8Unknown: Data = Data(count: 16)

    func encoded() -> Data {
        var w = BinaryWriter(reservingCapacity: Self.length)

        // Common MOBI block (232 bytes)
        w.writeMagic("MOBI")
        w.write(headerLength)
        w.write(mobiType)
        w.write(textEncoding)
        w.write(uniqueID)
        w.write(fileVersion)
        w.write(orthographicIndex)
        w.write(inflectionIndex)
        w.write(indexNames)
        w.write(indexKeys)
        w.write(extraIndex0)
        w.write(extraIndex1)
        w.write(extraIndex2)
        w.write(extraIndex3)
        w.write(extraIndex4)
        w.write(extraIndex5)
        w.write(firstNonBookIndex)
        w.write(fullNameOffset)
        w.write(fullNameLength)
        w.write(locale)
        w.write(inputLanguage)
        w.write(outputLanguage)
        w.write(minVersion)
        w.write(firstImageIndex)
        w.write(huffmanRecordOffset)
        w.write(huffmanRecordCount)
        w.write(huffmanTableOffset)
        w.write(huffmanTableLength)
        w.write(exthFlags)
        w.write(unknown1)
        w.write(drmOffset)
        w.write(drmCount)
        w.write(drmSize)
        w.write(drmFlags)
        w.write(unknown2)
        w.write(fdstNumberMSB)
        w.write(fdstNumberLSB)
        w.write(fdstEntryCount)
        w.write(fcisRecordNumber)
        w.write(fcisRecordCount)
        w.write(flisRecordNumber)
        w.write(flisRecordCount)
        // UInt64 written as two UInt32s so we don't need a UInt64
        // primitive on BinaryWriter just for this one field.
        w.write(UInt32(unknown4 >> 32))
        w.write(UInt32(unknown4 & 0xFFFF_FFFF))
        w.write(unknown5)
        w.write(firstCompilationSectionCount)
        w.write(compilationSectionCount)
        w.write(unknown6)
        w.write(extraRecordDataFlags)
        w.write(indxRecordOffset)

        // KF8 extension (32 bytes)
        w.write(chunkIndex)
        w.write(skeletonIndex)
        w.write(huffmanTableIndex)
        w.write(guideIndex)
        w.write(kf8Unknown)

        assert(
            w.count == Self.length, "KF8Header serialised to \(w.count) bytes, expected \(Self.length)")
        return w.data
    }
}
