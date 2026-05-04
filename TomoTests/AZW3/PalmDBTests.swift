import Foundation
import Testing

@testable import Tomo

@Suite("PalmDB")
struct PalmDBTests {

    // MARK: - Header size & magic

    @Test func emptyDatabaseIs80Bytes() {
        // 78-byte PalmDB header + 2-byte padding before (zero) record bodies.
        let db = PalmDB.Database(name: "Test", date: .palmEpoch)
        #expect(db.encoded().count == 80)
    }

    @Test func headerCarriesBookMobiMagic() {
        let db = PalmDB.Database(name: "Test", date: .palmEpoch)
        let bytes = Array(db.encoded())
        // "BOOK" at offsets 60-63, "MOBI" at offsets 64-67 — these tags
        // identify the file as a Mobipocket-derived PalmDB to anything
        // parsing the format.
        #expect(Array(bytes[60..<64]) == [0x42, 0x4F, 0x4F, 0x4B])
        #expect(Array(bytes[64..<68]) == [0x4D, 0x4F, 0x42, 0x49])
    }

    // MARK: - Name

    @Test func nameOccupiesFirst32BytesZeroPadded() {
        let db = PalmDB.Database(name: "AB", date: .palmEpoch)
        let bytes = Array(db.encoded())
        #expect(bytes[0] == 0x41)  // 'A'
        #expect(bytes[1] == 0x42)  // 'B'
        // Remaining 30 bytes of the name field are zero-padded.
        #expect(Array(bytes[2..<32]) == Array(repeating: 0, count: 30))
    }

    @Test func longNameIsTruncatedKeepingTrailingZero() {
        // 33-character name forced into a 32-byte field. The fixed-string
        // writer keeps the last byte zero per PalmDB conventions, so 31
        // bytes of content + 1 trailing zero.
        let longName = String(repeating: "X", count: 33)
        let db = PalmDB.Database(name: longName, date: .palmEpoch)
        let bytes = Array(db.encoded())
        for i in 0..<31 {
            #expect(bytes[i] == 0x58)  // 'X'
        }
        #expect(bytes[31] == 0x00)
    }

    // MARK: - Date encoding

    @Test func palmEpochEncodesAsZero() {
        let db = PalmDB.Database(name: "T", date: .palmEpoch)
        let bytes = Array(db.encoded())
        // CreationTime / ModificationTime / BackupTime — three uint32 fields
        // at offsets 36, 40, 44.
        #expect(readUInt32(bytes, at: 36) == 0)
        #expect(readUInt32(bytes, at: 40) == 0)
        #expect(readUInt32(bytes, at: 44) == 0)
    }

    @Test func unixEpochEncodesAsPalmOffset() {
        // 1970-01-01 = 1904-01-01 + 66 years = 2_082_844_800 seconds.
        let db = PalmDB.Database(name: "T", date: Date(timeIntervalSince1970: 0))
        let bytes = Array(db.encoded())
        #expect(readUInt32(bytes, at: 36) == 2_082_844_800)
    }

    // MARK: - Record count & last-UID

    @Test func numRecordsFieldMatches() {
        let db = PalmDB.Database(
            name: "T", date: .palmEpoch,
            records: [
                PalmDB.RawRecord(Data([0x01])),
                PalmDB.RawRecord(Data([0x02, 0x02])),
                PalmDB.RawRecord(Data([0x03, 0x03, 0x03])),
            ])
        let bytes = Array(db.encoded())
        #expect(readUInt16(bytes, at: 76) == 3)
    }

    @Test func lastRecordUIDIsTwoNMinusOne() {
        let db = PalmDB.Database(
            name: "T", date: .palmEpoch,
            records: [
                PalmDB.RawRecord(Data([0x01])),
                PalmDB.RawRecord(Data([0x02])),
                PalmDB.RawRecord(Data([0x03])),
            ])
        let bytes = Array(db.encoded())
        // 3 records → last UID = 3*2 - 1 = 5.
        #expect(readUInt32(bytes, at: 68) == 5)
    }

    @Test func emptyDatabaseLastRecordUIDWraps() {
        // 0 records produces unsigned underflow → UInt32.max. Matches
        // leotaku/mobi byte-for-byte; the value is meaningless without
        // records but must match the reference for diffing.
        let db = PalmDB.Database(name: "T", date: .palmEpoch)
        let bytes = Array(db.encoded())
        #expect(readUInt32(bytes, at: 68) == 0xFFFF_FFFF)
    }

    // MARK: - Record header layout

    @Test func singleRecordOffsetsAndSize() {
        let payload = Data([0xAA, 0xBB, 0xCC])
        let db = PalmDB.Database(
            name: "T", date: .palmEpoch,
            records: [
                PalmDB.RawRecord(payload)
            ])
        let bytes = Array(db.encoded())
        // 78 (header) + 8 (one record header) + 2 (padding) + 3 (payload) = 91.
        #expect(bytes.count == 91)
        // First record header sits immediately after the 78-byte file header.
        #expect(readUInt32(bytes, at: 78) == 88)  // offset = 78 + 8 + 2
        // Attribute and Skip bytes are zero (we don't use them).
        #expect(bytes[82] == 0)
        #expect(bytes[83] == 0)
        // UniqueID for index 0 is 0 (per leotaku/Calibre convention: i*2).
        #expect(readUInt16(bytes, at: 84) == 0)
        // 2-byte zero padding between record headers and bodies.
        #expect(bytes[86] == 0)
        #expect(bytes[87] == 0)
        // Payload appears verbatim at the offset declared in the header.
        #expect(Array(bytes[88..<91]) == [0xAA, 0xBB, 0xCC])
    }

    @Test func multipleRecordOffsetsCascade() {
        let r1 = Data([0x01, 0x02])  // 2 bytes
        let r2 = Data([0x03, 0x04, 0x05])  // 3 bytes
        let r3 = Data([0x06])  // 1 byte
        let db = PalmDB.Database(
            name: "T", date: .palmEpoch,
            records: [
                PalmDB.RawRecord(r1),
                PalmDB.RawRecord(r2),
                PalmDB.RawRecord(r3),
            ])
        let bytes = Array(db.encoded())

        // Initial body offset = 78 + 8*3 + 2 = 104.
        #expect(readUInt32(bytes, at: 78) == 104)  // r1 starts here
        #expect(readUInt32(bytes, at: 78 + 8) == 106)  // r1 was 2 bytes
        #expect(readUInt32(bytes, at: 78 + 16) == 109)  // r1 + r2 = 5 bytes

        // UniqueIDs are i*2 — the last 2 bytes of each 8-byte record header.
        #expect(readUInt16(bytes, at: 78 + 6) == 0)
        #expect(readUInt16(bytes, at: 78 + 8 + 6) == 2)
        #expect(readUInt16(bytes, at: 78 + 16 + 6) == 4)

        // Bodies appear back-to-back at the declared offsets.
        #expect(Array(bytes[104..<106]) == [0x01, 0x02])
        #expect(Array(bytes[106..<109]) == [0x03, 0x04, 0x05])
        #expect(Array(bytes[109..<110]) == [0x06])
    }
}

// MARK: - Test helpers

extension Date {
    /// 1904-01-01 00:00:00 UTC — the PalmDB / Mac OS Classic epoch.
    /// Encoded as zero in PalmDB time fields.
    fileprivate static let palmEpoch = Date(timeIntervalSince1970: -2_082_844_800)
}

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
