import Foundation

/// One slice of the combined HTML+CSS text stream, prefixed with the
/// payload bytes and followed by trailing-data bytes (multibyte hint
/// + chapter strand + length suffix). PalmDoc decompression normally
/// runs over `data` here; in our Phase 1 build we ship uncompressed,
/// which Kindle accepts when the PalmDoc header reports
/// `compression = 1`.
nonisolated struct TextRecord: PalmDB.Record {
    /// Maximum decompressed bytes per record. The PalmDoc header's
    /// RecordSize field reports this; readers slice the byte stream
    /// at exactly this boundary.
    static let maxSize = 0x1000   // 4096

    let data: Data
    let trail: Data

    init(text: Data, trail: TrailingData) {
        precondition(text.count <= Self.maxSize,
            "TextRecord payload is \(text.count) bytes, max is \(Self.maxSize)")
        self.data = text
        self.trail = trail.encoded()
    }

    func encoded() -> Data {
        var w = BinaryWriter(reservingCapacity: data.count + trail.count)
        w.write(data)
        w.write(trail)
        return w.data
    }

    /// Bytes-on-disk for this record. Used by the writer to detect
    /// when the last record needs a 4-byte alignment pad after it.
    var length: Int { data.count + trail.count }
}
