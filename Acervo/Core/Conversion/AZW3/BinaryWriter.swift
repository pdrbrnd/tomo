import Foundation

/// Append-only big-endian byte buffer used to assemble PalmDB / MOBI / KF8
/// binary structures. All multi-byte integers are written in network byte
/// order — that's the wire format of every record type in the AZW3 stack.
nonisolated struct BinaryWriter: Sendable {
    private(set) var data: Data

    init(reservingCapacity capacity: Int = 0) {
        self.data = Data(capacity: capacity)
    }

    var count: Int { data.count }

    mutating func write(_ value: UInt8) {
        data.append(value)
    }

    mutating func write(_ value: UInt16) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    mutating func write(_ value: UInt32) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    mutating func write(_ bytes: Data) {
        data.append(bytes)
    }

    mutating func write(contentsOf bytes: some Sequence<UInt8>) {
        data.append(contentsOf: bytes)
    }

    /// Writes a UTF-8 string into a fixed-width buffer, zero-padded on the
    /// right and truncated to leave a trailing zero byte. Matches the
    /// PalmDB header's 32-byte name field semantics.
    mutating func writeFixedString(_ string: String, width: Int) {
        precondition(width > 0, "Fixed-width string must have positive width")
        let truncated = Array(string.utf8.prefix(width - 1))
        data.append(contentsOf: truncated)
        data.append(contentsOf: repeatElement(0, count: width - truncated.count))
    }

    /// Writes a fixed-size 4-byte ASCII tag like "BOOK" or "MOBI". Crashes on
    /// anything that isn't exactly 4 bytes — these tags are baked into the
    /// PalmDB / MOBI specs and any drift is a programming error.
    mutating func writeMagic(_ tag: String) {
        let bytes = Array(tag.utf8)
        precondition(bytes.count == 4, "Magic must be exactly 4 bytes (got '\(tag)')")
        data.append(contentsOf: bytes)
    }

    mutating func writeZeros(_ count: Int) {
        guard count > 0 else { return }
        data.append(contentsOf: repeatElement(0, count: count))
    }
}
