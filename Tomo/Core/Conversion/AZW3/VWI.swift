import Foundation

/// Variable-width integer encoder, the format MOBI uses to embed
/// integers of unknown size into INDX/CNCX records. Each output byte
/// carries 7 bits of the integer; the most-significant byte has its
/// high bit set to mark the end of the run. Bytes are big-endian
/// (MSB first).
///
/// Examples:
///   0      → [0x80]
///   5      → [0x85]
///   128    → [0x01, 0x80]
///   16383  → [0x7F, 0xFF]
///
/// Direct port of leotaku/mobi's `encodeVwi`. Negative inputs are not
/// representable in the format and trip a precondition.
nonisolated func encodeVWI(_ value: Int) -> Data {
    precondition(value >= 0, "VWI requires a non-negative integer")
    if value == 0 {
        return Data([0x80])
    }
    var bytes: [UInt8] = []
    var x = value
    while x > 0 {
        bytes.append(UInt8(x & 0x7F))
        x >>= 7
    }
    // The terminator bit goes on what will become the LAST byte after
    // we reverse to MSB-first order. Pre-reverse, that's index 0.
    bytes[0] |= 0x80
    bytes.reverse()
    return Data(bytes)
}
