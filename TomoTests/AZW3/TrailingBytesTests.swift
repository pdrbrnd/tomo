import Foundation
import Testing

@testable import Tomo

@Suite("TrailingData encoding")
struct TrailingDataTests {

    @Test func emptyDataIsTwoBytes() {
        // multibyte=0, no strand → payload is one zero byte; length
        // suffix VWI(1) = 0x81. Total = 2 bytes.
        let data = TrailingData(multibyte: 0).encoded()
        #expect(Array(data) == [0x00, 0x81])
    }

    @Test func nonzeroMultibyteIsCarried() {
        let data = TrailingData(multibyte: 2).encoded()
        // payload = [0x02], VWI(1) = 0x81.
        #expect(Array(data) == [0x02, 0x81])
    }

    @Test func strandPayloadAppearsBeforeLengthSuffix() {
        var td = TrailingData()
        td.strand = StrandData(index: 0, tbsType: 8)
        let bytes = Array(td.encoded())
        // payload = [multibyte=0] + strand bytes.
        // The last byte must be the VWI-encoded length of the prefix.
        let lengthSuffixIndex = bytes.count - 1
        #expect(bytes[lengthSuffixIndex] & 0x80 == 0x80)  // VWI terminator
    }
}

@Suite("StrandData encoding")
struct StrandDataTests {

    @Test func indexShiftedThreeBitsLeft() {
        // Plain strand with index=2, all flags off, no tbsType.
        // value = 2 << 3 = 16. Single-byte VWI: 16 | 0x80 = 0x90.
        let strand = StrandData(index: 2, tbsType: 0)
        #expect(Array(strand.encoded()) == [0x90])
    }

    @Test func tbsTypeFlagAddsExtraVWI() {
        // index=0, tbsType=8: header VWI = (0<<3)|0b0010 = 2 = 0x82.
        // Followed by VWI(8) = 0x88.
        let strand = StrandData(index: 0, tbsType: 8)
        #expect(Array(strand.encoded()) == [0x82, 0x88])
    }

    @Test func numSiblingsByteEmittedOnlyAboveOne() {
        // numSiblings=2 → flag set, byte appended.
        let twoSibs = StrandData(index: 0, tbsType: 8, numSiblings: 2)
        let bytes = Array(twoSibs.encoded())
        // Header VWI: (0<<3)|0b0010|0b0100 = 6 = 0x86. Then VWI(8) = 0x88,
        // then numSiblings byte = 2.
        #expect(bytes == [0x86, 0x88, 0x02])

        // numSiblings=1 → flag NOT set, no byte.
        let oneSib = StrandData(index: 0, tbsType: 8, numSiblings: 1)
        // Header VWI: (0<<3)|0b0010 = 2. Then VWI(8) = 0x88. No siblings byte.
        #expect(Array(oneSib.encoded()) == [0x82, 0x88])
    }

    @Test func doesSpanAppendsZeroVWI() {
        // doesSpan=true → flag bit + trailing VWI(0)=0x80.
        let strand = StrandData(index: 0, tbsType: 8, doesSpan: true)
        // Header VWI: (0<<3)|0b0001|0b0010 = 3 = 0x83. Then VWI(8) = 0x88.
        // Then VWI(0) = 0x80 because doesSpan.
        #expect(Array(strand.encoded()) == [0x83, 0x88, 0x80])
    }
}

@Suite("multibyteOverlap")
struct MultibyteOverlapTests {

    @Test func emptyRecordReturnsZero() {
        #expect(multibyteOverlap(in: Data()) == 0)
    }

    @Test func asciiOnlyReturnsZero() {
        let record = Data("Hello, world.".utf8)
        #expect(multibyteOverlap(in: record) == 0)
    }

    @Test func recordEndingOnCompleteTwoByteCharReturnsZero() {
        // "café" — 5 bytes UTF-8: 63 61 66 C3 A9. Ends with the
        // continuation byte A9, but the sequence is complete.
        let record = Data("café".utf8)
        #expect(multibyteOverlap(in: record) == 0)
    }

    @Test func recordEndingMidTwoByteSequenceReturnsOne() {
        // "ca" + just the starter byte of "fé" — 0xC3 alone.
        // 1 byte missing to complete the 2-byte sequence.
        var record = Data("ca".utf8)
        record.append(0xC3)
        #expect(multibyteOverlap(in: record) == 1)
    }

    @Test func recordEndingMidThreeByteSequenceWithStarterOnlyReturnsTwo() {
        // 0xE2 starts a 3-byte sequence. 2 continuation bytes still
        // expected in the next record.
        var record = Data("ab".utf8)
        record.append(0xE2)
        #expect(multibyteOverlap(in: record) == 2)
    }

    @Test func recordEndingMidThreeByteSequenceWithOneContReturnsOne() {
        // 0xE2 + 0x80 → starter + first continuation. 1 byte left.
        var record = Data("ab".utf8)
        record.append(0xE2)
        record.append(0x80)
        #expect(multibyteOverlap(in: record) == 1)
    }

    @Test func recordEndingMidFourByteSequenceWithStarterOnlyReturnsThree() {
        // 0xF0 starts a 4-byte sequence (e.g. emoji range).
        var record = Data()
        record.append(0xF0)
        #expect(multibyteOverlap(in: record) == 3)
    }

    @Test func emojiSplitInMiddleReturnsRemaining() {
        // "🎉" = F0 9F 8E 89. Split after byte 2 → 2 bytes remaining.
        var record = Data()
        record.append(0xF0)
        record.append(0x9F)
        #expect(multibyteOverlap(in: record) == 2)
    }
}

@Suite("TrailProvider")
struct TrailProviderTests {

    @Test func emptyChapterListProducesEmptyStrand() {
        let provider = TrailProvider(chapters: [])
        let trail = provider.get(from: 0, to: 100)
        #expect(trail.strand == nil)
        #expect(trail.multibyte == 0)
    }

    @Test func chapterContainingRangeMidwayHasDoesSpan() {
        // Chapter [0, 10000), record [100, 4196) — neither start nor
        // end aligns with a chapter boundary, so doesSpan flips on.
        // (`atExactBoundary` requires chapter.start == from OR
        // chapter.end == to.)
        let chapters = [ChapterInfo(title: "A", start: 0, length: 10000)]
        let trail = TrailProvider(chapters: chapters).get(from: 100, to: 4196)
        #expect(trail.strand?.index == 0)
        #expect(trail.strand?.doesSpan == true)
        #expect(trail.strand?.numSiblings == 0)
    }

    @Test func chapterStartAligningWithRecordStartIsExactBoundary() {
        // Chapter [0, 10000), record [0, 4096) — chapter.start == from,
        // so atExactBoundary is true → doesSpan is false.
        let chapters = [ChapterInfo(title: "A", start: 0, length: 10000)]
        let trail = TrailProvider(chapters: chapters).get(from: 0, to: 4096)
        #expect(trail.strand?.index == 0)
        #expect(trail.strand?.doesSpan == false)
    }

    @Test func recordEndingAtChapterBoundaryDoesNotSpan() {
        // Chapter spans [0, 4096); record [0, 4096) — both boundaries
        // align, so doesSpan stays false.
        let chapters = [ChapterInfo(title: "A", start: 0, length: 4096)]
        let trail = TrailProvider(chapters: chapters).get(from: 0, to: 4096)
        #expect(trail.strand?.doesSpan == false)
    }

    @Test func multipleChaptersInRangeAccumulateSiblings() {
        // Two short chapters each contained within a single 4096-byte
        // record. No chapter wholly contains the range (since each is
        // smaller than the range), so case 2 fires for both.
        let chapters = [
            ChapterInfo(title: "A", start: 0, length: 100),
            ChapterInfo(title: "B", start: 100, length: 200),
        ]
        let trail = TrailProvider(chapters: chapters).get(from: 0, to: 4096)
        #expect(trail.strand?.index == 0)
        #expect(trail.strand?.numSiblings == 2)
    }
}
