import Foundation
import Testing

@testable import Tomo

@Suite("INDXHeader")
struct INDXHeaderTests {

  @Test func defaultIs192Bytes() {
    #expect(INDXHeader().encoded().count == INDXHeader.length)
    #expect(INDXHeader().encoded().count == 192)
  }

  @Test func startsWithINDXMagic() {
    let bytes = Array(INDXHeader().encoded())
    #expect(Array(bytes[0..<4]) == [0x49, 0x4E, 0x44, 0x58])
  }

  @Test func headerLengthFieldIs192() {
    let bytes = Array(INDXHeader().encoded())
    #expect(readUInt32(bytes, at: 4) == 192)
  }

  @Test func indexEncodingIsUTF8() {
    let bytes = Array(INDXHeader().encoded())
    // IndexEncoding at offset 28 — must be 65001 (UTF-8) for all our text.
    #expect(readUInt32(bytes, at: 28) == 65001)
  }

  @Test func indexLanguageIsUInt32Max() {
    let bytes = Array(INDXHeader().encoded())
    // Offset 32 — UInt32.max means "no language constraint."
    #expect(readUInt32(bytes, at: 32) == UInt32.max)
  }
}

@Suite("IndexRecord")
struct IndexRecordTests {

  @Test func emptyRecordHasOnlyHeaderAndIDXTMagic() {
    let record = IndexRecord()
    let bytes = Array(record.encoded())
    // INDX header (192) + IDXT magic (4) = 196. lengthNoPadding%4
    // = 196%4 = 0, so no outer padding.
    #expect(bytes.count == 196)
    // INDX magic at the start.
    #expect(Array(bytes[0..<4]) == [0x49, 0x4E, 0x44, 0x58])
    // IDXT magic immediately after the header (no entries, no TAGX).
    #expect(Array(bytes[192..<196]) == [0x49, 0x44, 0x58, 0x54])
  }

  @Test func emptyRecordHasNoTAGXOffset() {
    let record = IndexRecord()
    let bytes = Array(record.encoded())
    // No TAGX table → tagxOffset field is 0.
    #expect(readUInt32(bytes, at: 180) == 0)
  }

  @Test func singleEntryRecordHasCorrectFraming() {
    let entry = Data([0xAA, 0xBB, 0xCC, 0xDD])  // 4 bytes
    let record = IndexRecord(idxtEntries: [entry])
    let bytes = Array(record.encoded())
    // 192 (INDX) + 4 (entry) + 0 (inner pad: 4%4) + 4 (IDXT magic)
    // + 2 (offset) + 0 (outer pad: 202%4=2 hmm wait)
    // Actually: lengthNoPadding = 192 + 4 + 1*2 + 4 + 0 = 202.
    // 202 % 4 = 2. Total = 204.
    #expect(bytes.count == 204)
    // Entry sits right after the 192-byte header.
    #expect(Array(bytes[192..<196]) == [0xAA, 0xBB, 0xCC, 0xDD])
    // IDXT magic follows (no inner padding because 4 % 4 == 0).
    #expect(Array(bytes[196..<200]) == [0x49, 0x44, 0x58, 0x54])
    // Single entry offset = 192 (where the entry starts).
    #expect(readUInt16(bytes, at: 200) == 192)
  }

  @Test func recordCountFieldMatchesEntries() {
    let record = IndexRecord(idxtEntries: [
      Data([0x01]),
      Data([0x02]),
      Data([0x03]),
    ])
    let bytes = Array(record.encoded())
    // IndexRecordCount field at offset 24.
    #expect(readUInt32(bytes, at: 24) == 3)
  }

  @Test func tagxBlockIsWrittenWhenTableIsPresent() {
    let record = IndexRecord(tagxTable: TAGXTable.skeleton)
    let bytes = Array(record.encoded())
    // TAGX magic at offset 192 (right after INDX header).
    #expect(Array(bytes[192..<196]) == [0x54, 0x41, 0x47, 0x58])
    // TAGX header length field = 12 + 3 tags * 4 = 24.
    #expect(readUInt32(bytes, at: 196) == 24)
    // ControlByteCount = 1.
    #expect(readUInt32(bytes, at: 200) == 1)
  }

  @Test func tagxOffsetFieldPointsAtBlock() {
    let record = IndexRecord(tagxTable: TAGXTable.skeleton)
    let bytes = Array(record.encoded())
    // tagxOffset field always points at INDX header length when TAGX is present.
    #expect(readUInt32(bytes, at: 180) == 192)
  }

  @Test func conformsToPalmDBRecord() {
    let record = IndexRecord(idxtEntries: [Data([0x42])])
    let database = PalmDB.Database(name: "T", date: .now, records: [record])
    #expect(database.encoded().count > 0)
  }

  @Test func multipleEntryOffsetsCascadeCorrectly() {
    // Three entries of varying lengths — verifies the IDXT offset
    // table correctly accumulates byte positions.
    let record = IndexRecord(idxtEntries: [
      Data(repeating: 0xAA, count: 4),  // 4 bytes
      Data(repeating: 0xBB, count: 7),  // 7 bytes
      Data(repeating: 0xCC, count: 3),  // 3 bytes
    ])
    let bytes = Array(record.encoded())
    // Entries are written in order starting at offset 192.
    // No TAGX table → no extra block.
    let entriesEnd = 192 + 4 + 7 + 3  // = 206
    let entriesLen = 4 + 7 + 3  // = 14
    let innerPad = entriesLen % 4  // = 2
    let idxtMagicAt = entriesEnd + innerPad  // = 208
    // IDXT magic should land at idxtStart.
    #expect(Array(bytes[idxtMagicAt..<idxtMagicAt + 4]) == [0x49, 0x44, 0x58, 0x54])
    // Offset table entries:
    let offsetTableAt = idxtMagicAt + 4
    #expect(readUInt16(bytes, at: offsetTableAt) == 192)  // first entry
    #expect(readUInt16(bytes, at: offsetTableAt + 2) == 196)  // 192 + 4
    #expect(readUInt16(bytes, at: offsetTableAt + 4) == 203)  // 196 + 7
  }

  @Test func innerPaddingInsertsZerosBeforeIDXT() {
    // Single 5-byte entry → inner pad = 5 % 4 = 1 zero byte.
    let record = IndexRecord(idxtEntries: [Data([0x11, 0x22, 0x33, 0x44, 0x55])])
    let bytes = Array(record.encoded())
    // Entry at offsets 192..196 (5 bytes).
    #expect(Array(bytes[192..<197]) == [0x11, 0x22, 0x33, 0x44, 0x55])
    // One byte of zero padding at offset 197.
    #expect(bytes[197] == 0x00)
    // IDXT magic at offset 198.
    #expect(Array(bytes[198..<202]) == [0x49, 0x44, 0x58, 0x54])
  }
}

private func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
  UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
}

private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
  UInt32(bytes[offset]) << 24
    | UInt32(bytes[offset + 1]) << 16
    | UInt32(bytes[offset + 2]) << 8
    | UInt32(bytes[offset + 3])
}
