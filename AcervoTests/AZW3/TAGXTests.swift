import Testing
import Foundation
@testable import Acervo

@Suite("TAGXTag")
struct TAGXTagTests {

    @Test func decomposesBigEndianByteOrder() {
        let tag = TAGXTag(0x01020304)
        #expect(tag.tagId == 0x01)
        #expect(tag.tagNum == 0x02)
        #expect(tag.bitmask == 0x03)
        #expect(tag.endMarker == 0x04)
    }

    @Test func endTagIsRecognised() {
        #expect(TAGXTag.end.isEnd == true)
        #expect(TAGXTag.entryPosition.isEnd == false)
    }

    @Test func canonicalConstantsHaveExpectedRawValues() {
        // Spot-check the constants that the leotaku reference defines.
        // A typo here would produce wrong control bytes downstream.
        #expect(TAGXTag.skeletonChunkCount.raw == 0x01010300)
        #expect(TAGXTag.skeletonGeometry.raw == 0x06020C00)
        #expect(TAGXTag.chunkGeometry.raw == 0x06020800)
        #expect(TAGXTag.end.raw == 0x00000001)
    }
}

@Suite("calculateControlByte")
struct CalculateControlByteTests {

    @Test func skeletonTableProducesExpectedByte() {
        // Hand-traced: SkeletonChunkCount contributes 2, SkeletonGeometry
        // contributes 8, total = 10.
        #expect(calculateControlByte(TAGXTable.skeleton) == 10)
    }

    @Test func chunkTableProducesExpectedByte() {
        // Each of the four chunk tags contributes one bit (1, 2, 4, 8),
        // total = 15.
        #expect(calculateControlByte(TAGXTable.chunk) == 15)
    }

    @Test func ncxSingleTableProducesExpectedByte() {
        // EntryPosition: bm=1 shifts=0 nentries=1 → 1
        // EntryLength:   bm=2 shifts=1 nentries=1 → 2
        // EntryNameOffset: bm=4 shifts=2 nentries=1 → 4
        // EntryDepthLevel: bm=8 shifts=3 nentries=1 → 8
        // Total = 15.
        #expect(calculateControlByte(TAGXTable.ncxSingle) == 15)
    }
}
