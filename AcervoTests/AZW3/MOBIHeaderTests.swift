import Testing
import Foundation
@testable import Acervo

@Suite("PalmDocHeader")
struct PalmDocHeaderTests {

    @Test func defaultsAreSixteenBytes() {
        let header = PalmDocHeader()
        #expect(header.encoded().count == PalmDocHeader.length)
        #expect(header.encoded().count == 16)
    }

    @Test func defaultCompressionIsNone() {
        // 1 = no compression. Phase 1 ships uncompressed; LZ77 (value 2)
        // is a Phase 2 optimisation.
        let header = PalmDocHeader()
        let bytes = Array(header.encoded())
        #expect(readUInt16(bytes, at: 0) == 1)
    }

    @Test func defaultRecordSizeIs4096() {
        let header = PalmDocHeader()
        let bytes = Array(header.encoded())
        // 0x1000 at offset 10
        #expect(readUInt16(bytes, at: 10) == 0x1000)
    }

    @Test func customFieldsLandAtRightOffsets() {
        var header = PalmDocHeader()
        header.compression = 2
        header.textLength = 0xDEAD_BEEF
        header.textRecordCount = 7
        header.encryption = 1
        let bytes = Array(header.encoded())
        #expect(readUInt16(bytes, at: 0) == 2)            // compression
        #expect(readUInt32(bytes, at: 4) == 0xDEAD_BEEF)   // textLength
        #expect(readUInt16(bytes, at: 8) == 7)             // textRecordCount
        #expect(readUInt16(bytes, at: 12) == 1)            // encryption
    }
}

@Suite("KF8Header")
struct KF8HeaderTests {

    @Test func defaultsAre264Bytes() {
        let header = KF8Header()
        // 232-byte common MOBI block + 32-byte KF8 extension.
        #expect(header.encoded().count == KF8Header.length)
        #expect(header.encoded().count == 264)
    }

    @Test func magicIsMobiAtOffsetZero() {
        let header = KF8Header()
        let bytes = Array(header.encoded())
        #expect(Array(bytes[0..<4]) == [0x4D, 0x4F, 0x42, 0x49]) // "MOBI"
    }

    @Test func declaredHeaderLengthMatchesActual() {
        let header = KF8Header()
        let bytes = Array(header.encoded())
        // HeaderLength field at offset 4 — readers use this to skip
        // past the header. Must report 264 for KF8.
        #expect(readUInt32(bytes, at: 4) == UInt32(KF8Header.length))
    }

    @Test func mobiTypeIsBook() {
        let header = KF8Header()
        let bytes = Array(header.encoded())
        // 2 = book
        #expect(readUInt32(bytes, at: 8) == 2)
    }

    @Test func textEncodingIsUTF8() {
        let header = KF8Header()
        let bytes = Array(header.encoded())
        // 65001 = UTF-8 (CP_UTF8)
        #expect(readUInt32(bytes, at: 12) == 65001)
    }

    @Test func fileVersionAndMinVersionAreEight() {
        // FileVersion=8 / MinVersion=8 mark this as KF8. Older Kindles
        // refuse to open the file; modern ones (firmware 4+) handle it.
        let header = KF8Header()
        let bytes = Array(header.encoded())
        // FileVersion at offset 20 (after magic+length+type+encoding+uniqueID).
        #expect(readUInt32(bytes, at: 20) == 8)
        // MinVersion at offset 88 (after 10 index slots + firstNonBookIndex
        // + fullNameOffset + fullNameLength + locale + inputLang + outputLang).
        #expect(readUInt32(bytes, at: 88) == 8)
    }

    @Test func indexSlotsAreUInt32MaxByDefault() {
        // The 10 index slot fields sit at offsets 24..63. Each is uint32.
        // Default is UInt32.max ("not present").
        let header = KF8Header()
        let bytes = Array(header.encoded())
        for slot in 0..<10 {
            #expect(readUInt32(bytes, at: 24 + slot * 4) == UInt32.max)
        }
    }

    @Test func exthFlagsMatchCalibreConvention() {
        let header = KF8Header()
        let bytes = Array(header.encoded())
        // EXTHFlags at offset 112 (after MinVersion + FirstImageIndex +
        // 4 Huffman fields). Calibre writes 0b1010000 = 80; copying it
        // is the safest choice for Kindle firmware compatibility.
        #expect(readUInt32(bytes, at: 112) == 0b1010000)
    }

    @Test func extraRecordDataFlagsEnableMultibyteHints() {
        let header = KF8Header()
        let bytes = Array(header.encoded())
        // ExtraRecordDataFlags = 0b11. Tells Kindle to look for the
        // multibyte / trailing-byte hints at the end of each text record.
        // Penultimate field of the 232-byte common block (last is
        // INDXRecordOffset at 228..231).
        #expect(readUInt32(bytes, at: 224) == 0b11)
    }

    @Test func kf8ExtensionDefaultsAreUInt32Max() {
        let header = KF8Header()
        let bytes = Array(header.encoded())
        // The 32-byte KF8 extension starts at offset 232. First 4 fields
        // are uint32 indexes that the writer fills in once records are
        // laid out — all default to "not assigned" = UInt32.max.
        #expect(readUInt32(bytes, at: 232) == .max) // chunkIndex
        #expect(readUInt32(bytes, at: 236) == .max) // skeletonIndex
        #expect(readUInt32(bytes, at: 240) == .max) // huffmanTableIndex
        #expect(readUInt32(bytes, at: 244) == .max) // guideIndex
        // Last 16 bytes are zero padding.
        #expect(Array(bytes[248..<264]) == Array(repeating: 0, count: 16))
    }

    @Test func customFullNameOffsetAndLengthAreEncoded() {
        var header = KF8Header()
        header.fullNameOffset = 0xCAFE_BABE
        header.fullNameLength = 42
        let bytes = Array(header.encoded())
        // FullNameOffset at offset 68, FullNameLength at offset 72
        // (right after the 10 index slots and firstNonBookIndex).
        #expect(readUInt32(bytes, at: 68) == 0xCAFE_BABE)
        #expect(readUInt32(bytes, at: 72) == 42)
    }

    @Test func unknown64FieldSplitsToTwoBigEndianUInt32s() {
        // unknown4 is a UInt64 field that BinaryWriter doesn't have a
        // primitive for, so encoded() splits it into high/low UInt32s.
        // A regression in the bit-shift order would still produce
        // 8 bytes but with the halves swapped — this test catches that.
        var header = KF8Header()
        header.unknown4 = 0x0123_4567_89AB_CDEF
        let bytes = Array(header.encoded())
        // unknown4 starts at offset 200 (after FLISRecordCount at 196).
        #expect(Array(bytes[200..<208]) == [
            0x01, 0x23, 0x45, 0x67,
            0x89, 0xAB, 0xCD, 0xEF,
        ])
    }
}

// MARK: - Helpers

private func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
    UInt16(bytes[offset]) << 8
        | UInt16(bytes[offset + 1])
}

private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset]) << 24
        | UInt32(bytes[offset + 1]) << 16
        | UInt32(bytes[offset + 2]) << 8
        | UInt32(bytes[offset + 3])
}
