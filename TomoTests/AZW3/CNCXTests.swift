import Foundation
import Testing

@testable import Tomo

@Suite("encodeCNCXString")
struct EncodeCNCXStringTests {

    @Test func emptyStringIsJustZeroLength() {
        // VWI(0) = [0x80], no UTF-8 bytes follow.
        #expect(Array(encodeCNCXString("")) == [0x80])
    }

    @Test func shortStringHasVWIPrefixThenBytes() {
        // "Hi" is 2 bytes. VWI(2) = [0x82]. Result = [0x82, 'H', 'i'].
        #expect(Array(encodeCNCXString("Hi")) == [0x82, 0x48, 0x69])
    }

    @Test func multibyteStringEncodesByteCount() {
        // "café" = 5 bytes UTF-8. VWI(5) = [0x85]. Five UTF-8 bytes follow.
        let bytes = Array(encodeCNCXString("café"))
        #expect(bytes[0] == 0x85)
        #expect(bytes.count == 6)
    }
}

@Suite("encodeINDXString")
struct EncodeINDXStringTests {

    @Test func shortLabelHasSingleLengthPrefix() {
        // "ABC" → length-byte 3 + 3 ASCII bytes.
        #expect(Array(encodeINDXString("ABC")) == [0x03, 0x41, 0x42, 0x43])
    }

    @Test func emptyLabelHasZeroLengthPrefix() {
        #expect(Array(encodeINDXString("")) == [0x00])
    }

    @Test func multibyteLabelCountsBytes() {
        // "é" is 2 UTF-8 bytes.
        #expect(Array(encodeINDXString("é")) == [0x02, 0xC3, 0xA9])
    }
}

@Suite("CNCXRecord")
struct CNCXRecordTests {

    @Test func emptyRecordIsEmptyData() {
        let record = CNCXRecord()
        #expect(record.encoded().isEmpty)
    }

    @Test func entriesAreConcatenatedThenPadded() {
        let record = CNCXRecord(entries: [
            Data([0x01, 0x02]),
            Data([0x03]),
        ])
        // lengthNoPadding = 3, padding = 3 % 4 = 3 → total 6 bytes.
        // Matches leotaku's quirky modulo-as-padding behaviour.
        let bytes = Array(record.encoded())
        #expect(bytes.count == 6)
        #expect(Array(bytes[0..<3]) == [0x01, 0x02, 0x03])
        #expect(Array(bytes[3..<6]) == [0, 0, 0])
    }

    @Test func noPaddingWhenLengthIsAlignedToFour() {
        // length = 4 → 4 % 4 = 0 → no padding written.
        let record = CNCXRecord(entries: [Data([0x01, 0x02, 0x03, 0x04])])
        let bytes = Array(record.encoded())
        #expect(bytes.count == 4)
        #expect(Array(bytes) == [0x01, 0x02, 0x03, 0x04])
    }

    @Test func conformsToPalmDBRecord() {
        let record = CNCXRecord(entries: [Data([0x42])])
        let database = PalmDB.Database(name: "T", date: .now, records: [record])
        #expect(database.encoded().count > 0)
    }
}
