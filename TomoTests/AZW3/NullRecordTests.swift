import Foundation
import Testing

@testable import Tomo

@Suite("NullRecord")
struct NullRecordTests {

  @Test func defaultRecordHasFixedFloorLength() {
    // PalmDoc(16) + KF8(264) + EXTH(12, empty section is aligned) +
    // FullName("X" = 1 byte) + 8KB padding.
    let record = NullRecord(fullName: "X")
    let expected = 16 + 264 + 12 + 1 + 8192
    #expect(record.encoded().count == expected)
  }

  @Test func palmDocHeaderSitsAtOffsetZero() {
    let record = NullRecord(fullName: "X")
    let bytes = Array(record.encoded())
    // PalmDoc header's first 2 bytes are the compression field — 1
    // for our default uncompressed mode.
    #expect(readUInt16(bytes, at: 0) == 1)
  }

  @Test func mobiHeaderSitsAfterPalmDocHeader() {
    let record = NullRecord(fullName: "X")
    let bytes = Array(record.encoded())
    // KF8/MOBI magic should appear at offset 16 (right after the
    // 16-byte PalmDoc header).
    #expect(Array(bytes[16..<20]) == [0x4D, 0x4F, 0x42, 0x49])
  }

  @Test func exthSectionFollowsMobiHeader() {
    let record = NullRecord(fullName: "X")
    let bytes = Array(record.encoded())
    // EXTH magic at offset 16 + 264 = 280.
    #expect(Array(bytes[280..<284]) == [0x45, 0x58, 0x54, 0x48])
  }

  @Test func fullNameBytesAreWritten() {
    let record = NullRecord(fullName: "Frankenstein")
    let bytes = Array(record.encoded())
    // FullName starts after PalmDoc(16) + KF8(264) + EXTH(12 empty).
    let start = 16 + 264 + 12
    let nameBytes = Array("Frankenstein".utf8)
    #expect(Array(bytes[start..<start + nameBytes.count]) == nameBytes)
  }

  @Test func mobiHeaderFullNameOffsetMatchesActualPosition() {
    // FullNameOffset must point to where the name actually lives so
    // EXTH-aware readers (KindleUnpack, real Kindle firmware) can
    // recover the canonical title.
    let record = NullRecord(fullName: "Frankenstein")
    let bytes = Array(record.encoded())
    // FullNameOffset is uint32 at offset 68 of the MOBI header,
    // which itself is at offset 16. Absolute offset = 84.
    let storedOffset = readUInt32(bytes, at: 16 + 68)
    let expectedOffset = UInt32(16 + 264 + 12)  // PalmDoc + KF8 + EXTH(12 empty)
    #expect(storedOffset == expectedOffset)
  }

  @Test func mobiHeaderFullNameLengthIsBytesNotCharacters() {
    // "é" is 2 bytes in UTF-8. The header must report the byte
    // count, not the character count — readers slice the buffer by
    // bytes.
    let record = NullRecord(fullName: "é")
    let bytes = Array(record.encoded())
    // FullNameLength at offset 72 of the MOBI header (which sits at
    // offset 16 of the Null record). Absolute offset = 88.
    let storedLength = readUInt32(bytes, at: 16 + 72)
    #expect(storedLength == 2)
  }

  @Test func encodingDoesNotMutateTheRecord() {
    // The KF8 header gets fullNameOffset/length stamped during
    // serialisation. That mutation must be local — calling
    // encoded() twice should produce identical output regardless of
    // how the offset would shift if the EXTH grew between calls.
    var record = NullRecord(fullName: "Test")
    let first = record.encoded()
    record.exth.add(.title, string: "Test")
    let second = record.encoded()
    // The second pass must reflect the updated EXTH (different
    // bytes), not stale offset state.
    #expect(first.count != second.count)
    // And running encoded() twice on the now-updated record must
    // be idempotent.
    #expect(record.encoded() == record.encoded())
  }

  @Test func exthEntriesFlowThroughToBytes() {
    var record = NullRecord(fullName: "Frankenstein")
    record.exth.add(.title, string: "Frankenstein")
    record.exth.add(.author, string: "Mary Shelley")
    record.exth.add(.language, string: "en-GB")
    let bytes = Array(record.encoded())
    // EXTH entry count at offset 16 (KF8) + 264 + 8 (in EXTH header).
    #expect(readUInt32(bytes, at: 16 + 264 + 8) == 3)
  }

  @Test func conformsToPalmDBRecord() {
    // Compile-time check: NullRecord can stand in wherever the
    // PalmDB.Database expects records.
    let record = NullRecord(fullName: "X")
    let database = PalmDB.Database(name: "Test", date: .now, records: [record])
    #expect(database.encoded().count > 0)
  }

  @Test func callerMutatedMobiFieldsSurviveEncoding() {
    // The AZW3 writer will need to stamp record numbers (FCIS, FLIS,
    // FDST, chunk/skeleton indices) onto the MOBI header before
    // encoding. Confirms that mutations on `record.mobi.*` flow
    // through `encoded()` — encoded() makes a local copy only to
    // avoid stomping on fullName fields, which must not invalidate
    // unrelated caller mutations.
    var record = NullRecord(fullName: "X")
    record.mobi.fcisRecordNumber = 7
    record.mobi.flisRecordNumber = 9
    record.mobi.fdstNumberMSB = 0xABCD
    let bytes = Array(record.encoded())
    // Offsets relative to the Null record: 16 (PalmDoc) + MOBI offsets.
    #expect(readUInt32(bytes, at: 16 + 184) == 7)  // fcisRecordNumber
    #expect(readUInt32(bytes, at: 16 + 192) == 9)  // flisRecordNumber
    #expect(readUInt16(bytes, at: 16 + 176) == 0xABCD)  // fdstNumberMSB
  }

  @Test func multibyteFullNameLandsAtDeclaredOffset() {
    // Cross-checks the contract: the MOBI header's FullNameOffset
    // points to the actual UTF-8 bytes of the name, not somewhere
    // adjacent. A regression in offset math could pass the length
    // test but place the bytes at the wrong position.
    let name = "Frânkënstéin"
    let record = NullRecord(fullName: name)
    let bytes = Array(record.encoded())
    let storedOffset = Int(readUInt32(bytes, at: 16 + 68))
    let storedLength = Int(readUInt32(bytes, at: 16 + 72))
    let nameBytes = Array(name.utf8)
    #expect(storedLength == nameBytes.count)
    #expect(Array(bytes[storedOffset..<storedOffset + storedLength]) == nameBytes)
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
