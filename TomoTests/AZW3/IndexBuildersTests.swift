import Foundation
import Testing

@testable import Tomo

@Suite("to32")
struct To32Tests {

  @Test func zeroPadsToFourCharacters() {
    #expect(to32(0) == "0000")
  }

  @Test func smallValuesUseDigits() {
    #expect(to32(9) == "0009")
    #expect(to32(10) == "000A")
    #expect(to32(31) == "000V")  // last single-digit base-32
  }

  @Test func valuesAboveFirstByteUseTwoDigits() {
    #expect(to32(32) == "0010")
    #expect(to32(1023) == "00VV")  // 31*32 + 31
  }

  @Test func longValuesNotPadded() {
    // Past 4 digits (32^4 = 1048576) the string is returned as-is.
    #expect(to32(32 * 32 * 32 * 32) == "10000")
  }
}

@Suite("Skeleton header index record")
struct SkeletonHeaderIndexRecordTests {

  @Test func entryFormatIsLabelThenCountPlusPadding() {
    let record = skeletonHeaderIndexRecord(entryCount: 1)
    #expect(record.idxtEntries.count == 1)
    let entry = Array(record.idxtEntries[0])
    // Label: length byte + "SKEL" + 10 zero-padded digits ("0000000000")
    // = 1 + 4 + 10 = 15 bytes.
    #expect(entry[0] == 14)  // 14-char label
    #expect(Array(entry[1..<5]) == [0x53, 0x4B, 0x45, 0x4C])  // "SKEL"
    #expect(Array(entry[5..<15]) == Array(repeating: 0x30, count: 10))  // "0000000000"
    // Followed by uint16 BE entryCount (1) + 3 zero bytes.
    #expect(entry[15] == 0x00)
    #expect(entry[16] == 0x01)
    #expect(Array(entry[17..<20]) == [0, 0, 0])
  }

  @Test func usesSkeletonTAGXTable() {
    let record = skeletonHeaderIndexRecord(entryCount: 5)
    #expect(record.tagxTable == TAGXTable.skeleton)
    #expect(record.type == 2)
    #expect(record.subEntryCount == 5)
  }
}

@Suite("Chunk header index record")
struct ChunkHeaderIndexRecordTests {

  @Test func labelEncodesLastPosition() {
    let record = chunkHeaderIndexRecord(lastPos: 12345, entryCount: 3)
    let entry = Array(record.idxtEntries[0])
    // Label: length 10 + "0000012345"
    #expect(entry[0] == 10)
    #expect(Array(entry[1..<11]) == Array("0000012345".utf8))
  }

  @Test func declaresCNCXCount() {
    let record = chunkHeaderIndexRecord(lastPos: 0, entryCount: 1)
    #expect(record.cncxCount == 1)
  }
}

@Suite("NCX header index record")
struct NCXHeaderIndexRecordTests {

  @Test func labelIsThreeCharacterEntryCount() {
    let record = ncxHeaderIndexRecord(entryCount: 5)
    let entry = Array(record.idxtEntries[0])
    // Label = "%03d" of (5-1) = "004"
    #expect(entry[0] == 3)
    #expect(Array(entry[1..<4]) == Array("004".utf8))
  }

  @Test func usesNCXSingleTable() {
    let record = ncxHeaderIndexRecord(entryCount: 2)
    #expect(record.tagxTable == TAGXTable.ncxSingle)
    #expect(record.cncxCount == 1)
  }
}

@Suite("Skeleton index record (data)")
struct SkeletonIndexRecordTests {

  @Test func emptyChunksProducesEmptyEntries() {
    let record = skeletonIndexRecord(chunks: [])
    #expect(record.idxtEntries.isEmpty)
    #expect(record.headerType == 1)
    #expect(record.type == 0)
  }

  @Test func entryStartsWithIndexedSKELLabel() {
    let chunks = [
      ChunkInfo(preStart: 0, preLength: 100, contentStart: 100, contentLength: 50),
      ChunkInfo(preStart: 150, preLength: 80, contentStart: 230, contentLength: 60),
    ]
    let record = skeletonIndexRecord(chunks: chunks)
    // First entry's label = "SKEL0000000000", second = "SKEL0000000001".
    let first = Array(record.idxtEntries[0])
    let second = Array(record.idxtEntries[1])
    #expect(Array(first[1..<15]) == Array("SKEL0000000000".utf8))
    #expect(Array(second[1..<15]) == Array("SKEL0000000001".utf8))
  }
}

@Suite("Chunk index record (data)")
struct ChunkIndexRecordTests {

  @Test func cncxEntriesAreAidReferences() {
    let chunks = [
      ChunkInfo(preStart: 0, preLength: 0, contentStart: 0, contentLength: 100),
      ChunkInfo(preStart: 0, preLength: 0, contentStart: 100, contentLength: 50),
    ]
    let (_, cncx) = chunkIndexRecord(chunks: chunks)
    #expect(cncx.entries.count == 2)
    // First CNCX entry should encode "P-//*[@aid='0000']"
    // = length byte (or VWI) + the string bytes.
    let firstEntry = String(decoding: cncx.entries[0].dropFirst(), as: UTF8.self)
    #expect(firstEntry == "P-//*[@aid='0000']")
    let secondEntry = String(decoding: cncx.entries[1].dropFirst(), as: UTF8.self)
    #expect(secondEntry == "P-//*[@aid='0001']")
  }

  @Test func indexEntryHasContentStartLabel() {
    let chunks = [
      ChunkInfo(preStart: 0, preLength: 0, contentStart: 12345, contentLength: 100)
    ]
    let (record, _) = chunkIndexRecord(chunks: chunks)
    let entry = Array(record.idxtEntries[0])
    // Label = "%010d" of contentStart = "0000012345".
    #expect(entry[0] == 10)
    #expect(Array(entry[1..<11]) == Array("0000012345".utf8))
  }

  @Test func emptyInputProducesEmptyOutputs() {
    let (record, cncx) = chunkIndexRecord(chunks: [])
    #expect(record.idxtEntries.isEmpty)
    #expect(cncx.entries.isEmpty)
  }
}

@Suite("NCX index record (data)")
struct NCXIndexRecordTests {

  @Test func cncxHoldsChapterTitles() {
    let chapters = [
      ChapterInfo(title: "Prologue", start: 0, length: 100),
      ChapterInfo(title: "Chapter 1", start: 100, length: 200),
    ]
    let (_, cncx) = ncxIndexRecord(chapters: chapters)
    #expect(cncx.entries.count == 2)
    // First entry: VWI(8) = [0x88], then "Prologue" bytes.
    let first = Array(cncx.entries[0])
    #expect(first[0] == 0x88)
    #expect(Array(first[1...]) == Array("Prologue".utf8))
  }

  @Test func emptyInputProducesEmptyOutputs() {
    let (record, cncx) = ncxIndexRecord(chapters: [])
    #expect(record.idxtEntries.isEmpty)
    #expect(cncx.entries.isEmpty)
  }
}
