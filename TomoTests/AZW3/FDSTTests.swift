import Foundation
import Testing

@testable import Tomo

@Suite("FDSTRecord")
struct FDSTRecordTests {

    @Test func emptyRecordIsTwelveBytes() {
        let record = FDSTRecord()
        #expect(record.encoded().count == 12)
    }

    @Test func headerStartsWithFDSTMagic() {
        let record = FDSTRecord()
        let bytes = Array(record.encoded())
        #expect(Array(bytes[0..<4]) == [0x46, 0x44, 0x53, 0x54])
    }

    @Test func fixedHeaderLengthFieldIsTwelve() {
        // The header length field reports 12 regardless of how many
        // entries follow — readers use it to skip past the header.
        let record = FDSTRecord(entries: [
            .init(start: 0, end: 100),
            .init(start: 100, end: 200),
        ])
        let bytes = Array(record.encoded())
        #expect(readUInt32(bytes, at: 4) == 12)
    }

    @Test func entryCountMatchesActualEntries() {
        let record = FDSTRecord(entries: [
            .init(start: 0, end: 10),
            .init(start: 10, end: 20),
            .init(start: 20, end: 30),
        ])
        let bytes = Array(record.encoded())
        #expect(readUInt32(bytes, at: 8) == 3)
    }

    @Test func entriesLandAtCorrectOffsets() {
        let record = FDSTRecord(entries: [
            .init(start: 0, end: 0xCAFE),
            .init(start: 0xCAFE, end: 0xDEAD_BEEF),
        ])
        let bytes = Array(record.encoded())
        // First entry: offsets 12 (start) and 16 (end).
        #expect(readUInt32(bytes, at: 12) == 0)
        #expect(readUInt32(bytes, at: 16) == 0xCAFE)
        // Second entry: offsets 20 and 24.
        #expect(readUInt32(bytes, at: 20) == 0xCAFE)
        #expect(readUInt32(bytes, at: 24) == 0xDEAD_BEEF)
    }

    @Test func flowsConvenienceProducesBackToBackRanges() {
        // Three flows of lengths 5, 3, 7 produce ranges
        // [0..5], [5..8], [8..15].
        let record = FDSTRecord(flows: ["hello", "abc", "1234567"])
        #expect(record.entries.count == 3)
        #expect(record.entries[0] == .init(start: 0, end: 5))
        #expect(record.entries[1] == .init(start: 5, end: 8))
        #expect(record.entries[2] == .init(start: 8, end: 15))
    }

    @Test func flowsConvenienceCountsBytesNotCharacters() {
        // "café" is 5 bytes in UTF-8, not 4. The FDST byte ranges must
        // align with the byte stream the reader is parsing, so byte
        // count is the right unit.
        let record = FDSTRecord(flows: ["café"])
        #expect(record.entries.count == 1)
        #expect(record.entries[0] == .init(start: 0, end: 5))
    }

    @Test func totalEncodedSizeMatchesHeaderPlusEntries() {
        let record = FDSTRecord(entries: [
            .init(start: 0, end: 10),
            .init(start: 10, end: 20),
        ])
        // 12-byte header + 2 * 8-byte entries = 28 bytes.
        #expect(record.encoded().count == 28)
    }

    @Test func conformsToPalmDBRecord() {
        let record = FDSTRecord(flows: ["html"])
        let database = PalmDB.Database(
            name: "T", date: .now, records: [record]
        )
        #expect(database.encoded().count > 0)
    }
}

private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset]) << 24
        | UInt32(bytes[offset + 1]) << 16
        | UInt32(bytes[offset + 2]) << 8
        | UInt32(bytes[offset + 3])
}
