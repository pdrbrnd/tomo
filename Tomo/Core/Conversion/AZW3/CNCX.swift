import Foundation

/// CNCX record — a "continuation" record that holds the variable-width
/// string data referenced by chunk and NCX index entries. Each entry
/// is a VWI-encoded length followed by the UTF-8 string bytes; entries
/// are concatenated back-to-back with a small trailing pad.
nonisolated struct CNCXRecord: PalmDB.Record {
    var entries: [Data]

    init(entries: [Data] = []) {
        self.entries = entries
    }

    /// Length without the outer padding (matches leotaku's
    /// `LengthNoPadding`).
    var lengthNoPadding: Int {
        entries.reduce(0) { $0 + $1.count }
    }

    func encoded() -> Data {
        var w = BinaryWriter(reservingCapacity: lengthNoPadding + lengthNoPadding % 4)
        for entry in entries {
            w.write(entry)
        }
        // Same `length % 4` quirk as IndexRecord — works out to 4-aligned
        // in practice because of the doubled-up padding logic upstream.
        w.writeZeros(lengthNoPadding % 4)
        return w.data
    }
}

/// Encodes a string for use as a CNCX entry: a VWI-encoded length
/// prefix followed by the UTF-8 bytes.
nonisolated func encodeCNCXString(_ string: String) -> Data {
    let utf8 = Data(string.utf8)
    var result = encodeVWI(utf8.count)
    result.append(utf8)
    return result
}

/// Encodes a string for use as an INDX entry label: a single
/// length-byte prefix followed by the UTF-8 bytes. Limited to 255-byte
/// labels — none of the labels we use approach that.
nonisolated func encodeINDXString(_ string: String) -> Data {
    let utf8 = Array(string.utf8)
    precondition(utf8.count <= 255,
        "INDX label must fit in a single length byte (got \(utf8.count) bytes)")
    var bytes: [UInt8] = [UInt8(utf8.count)]
    bytes.append(contentsOf: utf8)
    return Data(bytes)
}
