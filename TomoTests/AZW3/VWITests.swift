import Foundation
import Testing

@testable import Tomo

@Suite("VWI")
struct VWITests {

  @Test func zeroEncodesAsTerminatorOnly() {
    // The 0x80 byte is just the terminator bit on a zero payload.
    #expect(Array(encodeVWI(0)) == [0x80])
  }

  @Test func singleByteValuesGetTerminatorBit() {
    // Values < 128 fit in one byte: payload | 0x80.
    #expect(Array(encodeVWI(5)) == [0x85])
    #expect(Array(encodeVWI(100)) == [0xE4])
    #expect(Array(encodeVWI(127)) == [0xFF])
  }

  @Test func twoByteBoundaryEncodes() {
    // 128 = 0b1000_0000 — needs two bytes: high byte (1), low byte (0|terminator).
    #expect(Array(encodeVWI(128)) == [0x01, 0x80])
  }

  @Test func multibyteValuesAreBigEndian() {
    // 16383 = 0b0011_1111_1111_1111 — fits in 14 bits, two bytes.
    // Hi = 0x7F, Lo = 0x7F | 0x80 = 0xFF.
    #expect(Array(encodeVWI(16383)) == [0x7F, 0xFF])
  }

  @Test func threeByteBoundaryEncodes() {
    // 16384 = 0b0100_0000_0000_0000 — needs 3 bytes (15 bits payload).
    // Bytes (MSB→LSB after reverse): 0x01, 0x00, 0x00 | 0x80 = 0x80.
    #expect(Array(encodeVWI(16384)) == [0x01, 0x00, 0x80])
    // 2^21-1 = 0x1FFFFF, biggest 3-byte value.
    #expect(Array(encodeVWI(2_097_151)) == [0x7F, 0x7F, 0xFF])
  }

  @Test func largeValuesProduceCorrectByteCount() {
    // 2^21 needs 4 bytes. Verify the count without pinning the exact
    // bytes — that's what the boundary tests above are for.
    let encoded = encodeVWI(1 << 21)
    #expect(encoded.count == 4)
    // Last byte has terminator bit set.
    #expect(encoded.last! & 0x80 == 0x80)
    // Earlier bytes don't have it set.
    for byte in encoded.dropLast() {
      #expect(byte & 0x80 == 0)
    }
  }
}
