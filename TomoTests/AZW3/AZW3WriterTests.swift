import Foundation
import Testing

@testable import Tomo

@Suite("AZW3Writer")
struct AZW3WriterTests {

  @Test func producesAFileStartingWithBookMobiPalmDB() {
    let manifest = BookManifest(
      title: "Frankenstein",
      authors: ["Mary Shelley"],
      language: "en-GB",
      chunks: ["<p>It was on a dreary night of November...</p>"]
    )
    let bytes = Array(AZW3Writer(manifest: manifest).encode())
    // PalmDB header type/creator at offsets 60-67.
    #expect(Array(bytes[60..<64]) == [0x42, 0x4F, 0x4F, 0x4B])  // "BOOK"
    #expect(Array(bytes[64..<68]) == [0x4D, 0x4F, 0x42, 0x49])  // "MOBI"
  }

  @Test func bookNameMatchesManifestTitle() {
    let manifest = BookManifest(
      title: "Custom Title",
      authors: [],
      language: "en",
      chunks: ["<p>x</p>"]
    )
    let bytes = Array(AZW3Writer(manifest: manifest).encode())
    // Name occupies first 32 bytes of PalmDB header.
    let nameBytes = bytes[0..<32]
    let name = String(decoding: Array(nameBytes).prefix(while: { $0 != 0 }), as: UTF8.self)
    #expect(name == "Custom Title")
  }

  @Test func recordCountIsExactly15ForOneSmallChunk() {
    // null (1) + text (1) + pad (1, because the text record's
    // length isn't a multiple of 4 for this fixed input)
    // + chunk INDX (header + data + cncx = 3)
    // + skeleton INDX (header + data = 2)
    // + NCX (header + data + cncx = 3)
    // + FDST (1) + FLIS (1) + FCIS (1) + EOF (1)
    // = 15.
    let manifest = BookManifest(
      title: "T", authors: [], language: "en",
      chunks: ["<p>x</p>"]
    )
    let bytes = Array(AZW3Writer(manifest: manifest).encode())
    let recordCount = (UInt16(bytes[76]) << 8) | UInt16(bytes[77])
    #expect(recordCount == 15)
  }

  @Test func endsWithEOFRecord() {
    let manifest = BookManifest(
      title: "T", authors: [], language: "en",
      chunks: ["<p>x</p>"]
    )
    let bytes = Array(AZW3Writer(manifest: manifest).encode())
    // EOF record is the last 4 bytes of the file.
    let suffix = Array(bytes.suffix(4))
    #expect(suffix == [0xE9, 0x8E, 0x0D, 0x0A])
  }

  @Test func nullRecordHasMOBIMagicAndKF8FileVersion() {
    let manifest = BookManifest(
      title: "T", authors: [], language: "en",
      chunks: ["<p>x</p>"]
    )
    let bytes = Array(AZW3Writer(manifest: manifest).encode())
    // The first record's offset is in bytes 78..81 (first record header).
    let firstRecOffset =
      (UInt32(bytes[78]) << 24)
      | (UInt32(bytes[79]) << 16)
      | (UInt32(bytes[80]) << 8)
      | UInt32(bytes[81])
    // The null record starts at that offset, then PalmDoc(16) + MOBI magic.
    let mobiMagicAt = Int(firstRecOffset) + 16
    #expect(Array(bytes[mobiMagicAt..<mobiMagicAt + 4]) == [0x4D, 0x4F, 0x42, 0x49])
    // FileVersion at MOBI offset 20 — should be 8 for KF8.
    let fileVersionAt = mobiMagicAt + 20
    let fileVersion =
      (UInt32(bytes[fileVersionAt]) << 24)
      | (UInt32(bytes[fileVersionAt + 1]) << 16)
      | (UInt32(bytes[fileVersionAt + 2]) << 8)
      | UInt32(bytes[fileVersionAt + 3])
    #expect(fileVersion == 8)
  }

  @Test func multibyteContentRoundtripsThroughTheStream() {
    // Portuguese accented text must survive encoding without
    // corruption. A multibyte char straddling a record boundary
    // is *not* yet handled (Phase 2 — see docs/azw3_phase2.md);
    // this test only checks the bytes are present somewhere in
    // the file.
    let manifest = BookManifest(
      title: "T", authors: [], language: "pt-PT",
      chunks: ["<p>Coração</p>"]
    )
    let bytes = AZW3Writer(manifest: manifest).encode()
    // "Coração" UTF-8 = 43 6F 72 61 C3 A7 C3 A3 6F.
    let needle = Data([0x43, 0x6F, 0x72, 0x61, 0xC3, 0xA7, 0xC3, 0xA3, 0x6F])
    #expect(bytes.range(of: needle) != nil)
  }

  @Test func textRecordCountMatchesPalmDocHeader() {
    // For a small chunk that fits in one 4096-byte text record,
    // PalmDocHeader.TextRecordCount must equal 1.
    let manifest = BookManifest(
      title: "T", authors: [], language: "en",
      chunks: ["<p>small</p>"]
    )
    let bytes = Array(AZW3Writer(manifest: manifest).encode())
    // Find first record offset (= start of null record).
    let firstRecOffset = Int(
      (UInt32(bytes[78]) << 24)
        | (UInt32(bytes[79]) << 16)
        | (UInt32(bytes[80]) << 8)
        | UInt32(bytes[81]))
    // PalmDocHeader.TextRecordCount at bytes 8-9 of the null record.
    let trcAt = firstRecOffset + 8
    let recordCount = (UInt16(bytes[trcAt]) << 8) | UInt16(bytes[trcAt + 1])
    #expect(recordCount == 1)
  }

  /// Parse PalmDB record offsets out of the produced bytes — used by
  /// the cross-reference test below to verify each MOBI-header
  /// "pointer" actually points at a record with the right magic.
  private func parseRecordOffsets(_ bytes: [UInt8]) -> [Int] {
    let recordCount = Int((UInt16(bytes[76]) << 8) | UInt16(bytes[77]))
    var offsets: [Int] = []
    offsets.reserveCapacity(recordCount)
    for i in 0..<recordCount {
      let start = 78 + i * 8
      let offset =
        (UInt32(bytes[start]) << 24)
        | (UInt32(bytes[start + 1]) << 16)
        | (UInt32(bytes[start + 2]) << 8)
        | UInt32(bytes[start + 3])
      offsets.append(Int(offset))
    }
    return offsets
  }

  @Test func crossReferencesPointAtCorrectRecords() {
    // The most valuable orchestration check: for every "pointer"
    // field in the MOBI header, follow the index through the
    // PalmDB record table and confirm we land on a record with
    // the right magic. Catches off-by-one bugs in the writer's
    // index stamping that would otherwise only show up on a real
    // Kindle.
    let manifest = BookManifest(
      title: "T", authors: [], language: "en",
      chunks: ["<p>x</p>"]
    )
    let bytes = Array(AZW3Writer(manifest: manifest).encode())
    let recordOffsets = parseRecordOffsets(bytes)
    let mobiStart = recordOffsets[0] + 16  // Skip PalmDoc header.

    func readUInt16(at off: Int) -> Int {
      Int((UInt16(bytes[off]) << 8) | UInt16(bytes[off + 1]))
    }
    func readUInt32(at off: Int) -> Int {
      Int(
        (UInt32(bytes[off]) << 24)
          | (UInt32(bytes[off + 1]) << 16)
          | (UInt32(bytes[off + 2]) << 8)
          | UInt32(bytes[off + 3]))
    }
    func magicAt(recordIndex: Int) -> [UInt8] {
      let off = recordOffsets[recordIndex]
      return Array(bytes[off..<off + 4])
    }

    // chunkIndex (offset 232 within MOBI header) → INDX record
    let chunkIdx = readUInt32(at: mobiStart + 232)
    #expect(magicAt(recordIndex: chunkIdx) == Array("INDX".utf8))

    // skeletonIndex (236) → INDX
    let skeletonIdx = readUInt32(at: mobiStart + 236)
    #expect(magicAt(recordIndex: skeletonIdx) == Array("INDX".utf8))

    // indxRecordOffset / NCX (228) → INDX
    let ncxIdx = readUInt32(at: mobiStart + 228)
    #expect(magicAt(recordIndex: ncxIdx) == Array("INDX".utf8))

    // FDST: MSB(176, UInt16) + LSB(178, UInt16). For our case MSB=0.
    #expect(readUInt16(at: mobiStart + 176) == 0)
    let fdstIdx = readUInt16(at: mobiStart + 178)
    #expect(magicAt(recordIndex: fdstIdx) == Array("FDST".utf8))

    // FLIS (192) → FLIS magic
    let flisIdx = readUInt32(at: mobiStart + 192)
    #expect(magicAt(recordIndex: flisIdx) == Array("FLIS".utf8))

    // FCIS (184) → FCIS magic
    let fcisIdx = readUInt32(at: mobiStart + 184)
    #expect(magicAt(recordIndex: fcisIdx) == Array("FCIS".utf8))
  }

  @Test func emitsRequiredEXTHEntries() {
    // Phase 1 emits title, updatedTitle, author (if any), language,
    // ASIN, and DocType. Some Kindle firmware versions reject
    // books without ASIN/DocType — so we want to confirm the
    // bytes are present even before hardware testing.
    let manifest = BookManifest(
      title: "Frankenstein", authors: ["Mary Shelley"],
      language: "en-GB", chunks: ["<p>x</p>"]
    )
    let bytes = AZW3Writer(manifest: manifest).encode()
    // ASIN (113), updatedTitle (503), docType (501) all carry
    // distinct UTF-8 needles. We don't parse the EXTH section
    // structure — we just look for the values.
    #expect(bytes.range(of: Data("EBOK".utf8)) != nil)  // docType
    #expect(bytes.range(of: Data("Mary Shelley".utf8)) != nil)  // author
    #expect(bytes.range(of: Data("en-GB".utf8)) != nil)  // language
    // The pseudo-ASIN is 15 lowercase hex chars derived from
    // the manifest. Just confirm a 15-char hex string appears.
    let bytesArr = Array(bytes)
    let lower = Set("0123456789abcdef".utf8)
    var found = false
    for i in 0..<(bytesArr.count - 15) where !found {
      let slice = bytesArr[i..<i + 15]
      if slice.allSatisfy({ lower.contains($0) }) {
        found = true
      }
    }
    #expect(found)
  }
}
