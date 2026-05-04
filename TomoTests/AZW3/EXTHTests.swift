import Foundation
import Testing

@testable import Tomo

@Suite("EXTHEntry")
struct EXTHEntryTests {

  @Test func lengthIncludesEightByteHeader() {
    let entry = EXTHEntry(type: .title, data: Data([0x41, 0x42, 0x43]))
    // 8-byte entry header + 3 bytes of payload.
    #expect(entry.length == 11)
  }

  @Test func encodedShapeIsTypeLengthPayload() {
    let entry = EXTHEntry(type: .author, data: Data([0xAA, 0xBB]))
    let bytes = Array(entry.encoded())
    // First 4 bytes: type code (100 = author).
    #expect(readUInt32(bytes, at: 0) == 100)
    // Next 4 bytes: total entry length including header (8 + 2 = 10).
    #expect(readUInt32(bytes, at: 4) == 10)
    // Then payload.
    #expect(Array(bytes[8..<10]) == [0xAA, 0xBB])
  }
}

@Suite("EXTHSection")
struct EXTHSectionTests {

  @Test func emptySectionIsTwelveBytes() {
    let section = EXTHSection()
    // Header alone (4-byte magic + 4 length + 4 entry count) = 12.
    // 12 is already a 4-byte multiple, so no padding.
    #expect(section.length == 12)
    #expect(section.encoded().count == 12)
  }

  @Test func headerStartsWithEXTHMagic() {
    let section = EXTHSection()
    let bytes = Array(section.encoded())
    #expect(Array(bytes[0..<4]) == [0x45, 0x58, 0x54, 0x48])  // "EXTH"
  }

  @Test func headerLengthFieldExcludesPadding() {
    // Add a string that forces non-zero padding:
    // header(12) + entry(8 + 3) = 23 → padded to 24.
    var section = EXTHSection()
    section.add(.title, string: "ABC")
    let bytes = Array(section.encoded())
    // lengthWithoutPadding = 23
    #expect(readUInt32(bytes, at: 4) == 23)
    // total bytes including padding = 24
    #expect(bytes.count == 24)
  }

  @Test func emptyStringIsSkipped() {
    var section = EXTHSection()
    section.add(.title, string: "")
    section.add(.author, string: "X")
    // Only the non-empty author entry was recorded.
    #expect(section.entries.count == 1)
    #expect(section.entries.first?.type == .author)
  }

  @Test func entryCountFieldMatches() {
    var section = EXTHSection()
    section.add(.title, string: "Frankenstein")
    section.add(.author, string: "Mary Shelley")
    section.add(.language, string: "en-GB")
    let bytes = Array(section.encoded())
    #expect(readUInt32(bytes, at: 8) == 3)
  }

  @Test func stringEntryEncodedAsUTF8() {
    var section = EXTHSection()
    section.add(.title, string: "ABC")
    let bytes = Array(section.encoded())
    // After the 12-byte EXTH header, the entry begins at offset 12.
    #expect(readUInt32(bytes, at: 12) == 99)  // .title = 99
    #expect(readUInt32(bytes, at: 16) == 11)  // entry length (8 + 3)
    #expect(Array(bytes[20..<23]) == [0x41, 0x42, 0x43])  // "ABC"
  }

  @Test func integerEntryEncodedAsBigEndian() {
    var section = EXTHSection()
    section.add(.title, integer: 0xDEAD_BEEF)
    let bytes = Array(section.encoded())
    // Type and length at offsets 12 and 16.
    #expect(readUInt32(bytes, at: 12) == 99)  // .title
    #expect(readUInt32(bytes, at: 16) == 12)  // 8 + 4
    #expect(readUInt32(bytes, at: 20) == 0xDEAD_BEEF)
  }

  @Test func multibyteStringsKeepBytePositions() {
    var section = EXTHSection()
    // "é" is 2 bytes in UTF-8 (0xC3 0xA9). The entry should declare
    // its length in bytes, not characters.
    section.add(.author, string: "é")
    let bytes = Array(section.encoded())
    #expect(readUInt32(bytes, at: 16) == 10)  // 8 + 2 bytes
    #expect(Array(bytes[20..<22]) == [0xC3, 0xA9])
  }

  @Test func paddingPadsToFourByteBoundary() {
    // header(12) + entry(8 + 1) = 21 → padded to 24.
    var section = EXTHSection()
    section.add(.title, string: "X")
    let bytes = Array(section.encoded())
    #expect(bytes.count == 24)
    #expect(section.paddingByteCount == 3)
    // Trailing 3 bytes are zero padding.
    #expect(Array(bytes[21..<24]) == [0, 0, 0])
  }

  @Test func zeroPaddingNeededWhenAlreadyAligned() {
    // header(12) + entry(8 + 4) = 24 → 0 bytes padding.
    var section = EXTHSection()
    section.add(.title, integer: 1)
    let bytes = Array(section.encoded())
    #expect(bytes.count == 24)
    #expect(section.paddingByteCount == 0)
  }
}

// MARK: - Helpers

private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
  UInt32(bytes[offset]) << 24
    | UInt32(bytes[offset + 1]) << 16
    | UInt32(bytes[offset + 2]) << 8
    | UInt32(bytes[offset + 3])
}
