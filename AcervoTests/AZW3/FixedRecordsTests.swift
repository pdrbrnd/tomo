import Testing
import Foundation
@testable import Acervo

@Suite("FLISRecord")
struct FLISRecordTests {

    @Test func isThirtySixBytes() {
        #expect(FLISRecord().encoded().count == FLISRecord.length)
        #expect(FLISRecord().encoded().count == 36)
    }

    @Test func startsWithFLISMagic() {
        let bytes = Array(FLISRecord().encoded())
        #expect(Array(bytes[0..<4]) == [0x46, 0x4C, 0x49, 0x53]) // "FLIS"
    }

    @Test func hasExpectedMagicValuesAtKeyOffsets() {
        // Spot-check the values that come straight from Calibre output.
        // If a refactor accidentally swaps any of these, Kindle may
        // refuse the book even though the layout looks superficially
        // valid.
        let bytes = Array(FLISRecord().encoded())
        #expect(readUInt32(bytes, at: 4) == 8)            // Fixed1
        #expect(readUInt16(bytes, at: 8) == 65)            // Fixed2
        #expect(readUInt32(bytes, at: 16) == UInt32.max)   // Fixed5
        #expect(readUInt32(bytes, at: 32) == UInt32.max)   // Fixed10
    }

    @Test func conformsToPalmDBRecord() {
        let database = PalmDB.Database(
            name: "T", date: .now, records: [FLISRecord()]
        )
        #expect(database.encoded().count > 0)
    }
}

@Suite("FCISRecord")
struct FCISRecordTests {

    @Test func isFiftyTwoBytes() {
        #expect(FCISRecord(textLength: 0).encoded().count == FCISRecord.length)
        #expect(FCISRecord(textLength: 0).encoded().count == 52)
    }

    @Test func startsWithFCISMagic() {
        let bytes = Array(FCISRecord(textLength: 0).encoded())
        #expect(Array(bytes[0..<4]) == [0x46, 0x43, 0x49, 0x53]) // "FCIS"
    }

    @Test func textLengthLandsAtOffset20() {
        // TextLength is the only variable field. Verifies the surrounding
        // fixed values don't accidentally shift its position.
        let bytes = Array(FCISRecord(textLength: 0xDEAD_BEEF).encoded())
        #expect(readUInt32(bytes, at: 20) == 0xDEAD_BEEF)
    }

    @Test func fixedFieldsMatchCalibreOutput() {
        let bytes = Array(FCISRecord(textLength: 1000).encoded())
        #expect(readUInt32(bytes, at: 4) == 20)   // Fixed1
        #expect(readUInt32(bytes, at: 8) == 16)   // Fixed2
        #expect(readUInt32(bytes, at: 12) == 2)   // Fixed3
        #expect(readUInt32(bytes, at: 28) == 40)  // Fixed6
        #expect(readUInt32(bytes, at: 36) == 40)  // Fixed8
        #expect(readUInt32(bytes, at: 40) == 8)   // Fixed9
    }
}

@Suite("EOFRecord")
struct EOFRecordTests {

    @Test func isFourBytes() {
        #expect(EOFRecord().encoded().count == EOFRecord.length)
        #expect(EOFRecord().encoded().count == 4)
    }

    @Test func emitsCalibreEOFMagic() {
        // The exact byte sequence Calibre writes. Kindle parsers
        // recognise this terminator and stop reading.
        #expect(Array(EOFRecord().encoded()) == [0xE9, 0x8E, 0x0D, 0x0A])
    }
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
