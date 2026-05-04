import Foundation
import Testing

@testable import Tomo

@Suite("BinaryWriter")
struct BinaryWriterTests {

    @Test func emptyWriterProducesEmptyData() {
        let writer = BinaryWriter()
        #expect(writer.data.isEmpty)
        #expect(writer.count == 0)
    }

    @Test func writesUInt8Verbatim() {
        var writer = BinaryWriter()
        writer.write(UInt8(0x42))
        #expect(Array(writer.data) == [0x42])
    }

    @Test func writesUInt16BigEndian() {
        var writer = BinaryWriter()
        writer.write(UInt16(0x1234))
        #expect(Array(writer.data) == [0x12, 0x34])
    }

    @Test func writesUInt32BigEndian() {
        var writer = BinaryWriter()
        writer.write(UInt32(0xDEAD_BEEF))
        #expect(Array(writer.data) == [0xDE, 0xAD, 0xBE, 0xEF])
    }

    @Test func writesMultiplePrimitivesInOrder() {
        var writer = BinaryWriter()
        writer.write(UInt8(0xAA))
        writer.write(UInt16(0xBBCC))
        writer.write(UInt32(0xDDEE_FF00))
        #expect(Array(writer.data) == [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00])
        #expect(writer.count == 7)
    }

    @Test func fixedStringPadsRightWithZeros() {
        var writer = BinaryWriter()
        writer.writeFixedString("Test", width: 10)
        #expect(Array(writer.data) == [0x54, 0x65, 0x73, 0x74, 0, 0, 0, 0, 0, 0])
    }

    @Test func fixedStringTruncatesAndKeepsTrailingZero() {
        var writer = BinaryWriter()
        // "Hello" needs 5 bytes; width 4 means 3 bytes of content + trailing zero.
        writer.writeFixedString("Hello", width: 4)
        #expect(Array(writer.data) == [0x48, 0x65, 0x6C, 0x00])
    }

    @Test func magicWritesExactFourBytes() {
        var writer = BinaryWriter()
        writer.writeMagic("BOOK")
        writer.writeMagic("MOBI")
        #expect(
            Array(writer.data) == [
                0x42, 0x4F, 0x4F, 0x4B,
                0x4D, 0x4F, 0x42, 0x49,
            ])
    }

    @Test func zerosAppendsPadding() {
        var writer = BinaryWriter()
        writer.write(UInt8(0xFF))
        writer.writeZeros(3)
        writer.write(UInt8(0xFF))
        #expect(Array(writer.data) == [0xFF, 0, 0, 0, 0xFF])
    }

    @Test func zerosWithZeroCountIsNoOp() {
        var writer = BinaryWriter()
        writer.writeZeros(0)
        #expect(writer.data.isEmpty)
    }

    @Test func writesRawData() {
        var writer = BinaryWriter()
        writer.write(Data([0x01, 0x02, 0x03]))
        #expect(Array(writer.data) == [0x01, 0x02, 0x03])
    }

    @Test func writesSequenceOfBytes() {
        var writer = BinaryWriter()
        writer.write(contentsOf: [UInt8(0x10), 0x20, 0x30])
        #expect(Array(writer.data) == [0x10, 0x20, 0x30])
    }
}
