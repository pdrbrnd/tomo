import Foundation

/// FDST record — the Flow Division Section Table for KF8 books. It
/// declares the byte ranges of each "flow" (concatenated text resource)
/// inside the combined text record stream. A book has at minimum one
/// flow (the HTML); additional flows are CSS files concatenated after
/// the HTML.
///
/// On disk:
///
///   [4]  "FDST"
///   [4]  Header length = 12
///   [4]  Entry count
///   [8]  Each entry: { uint32 start, uint32 end } byte offsets into
///        the combined text stream
nonisolated struct FDSTRecord: PalmDB.Record {
    static let headerLength = 12
    static let entryLength = 8

    /// One contiguous block of bytes in the combined text stream.
    nonisolated struct Entry: Sendable, Equatable {
        let start: UInt32
        let end: UInt32
    }

    let entries: [Entry]

    init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// Convenience init: takes flows as raw strings (HTML, CSS files,
    /// etc.) in declaration order and computes back-to-back byte
    /// ranges. Each flow's range starts where the previous one ended.
    init(flows: [String]) {
        var entries: [Entry] = []
        var offset = 0
        for flow in flows {
            let length = flow.utf8.count
            entries.append(Entry(start: UInt32(offset), end: UInt32(offset + length)))
            offset += length
        }
        self.entries = entries
    }

    func encoded() -> Data {
        let totalLength = Self.headerLength + entries.count * Self.entryLength
        var w = BinaryWriter(reservingCapacity: totalLength)
        w.writeMagic("FDST")
        w.write(UInt32(Self.headerLength))
        w.write(UInt32(entries.count))
        for entry in entries {
            w.write(entry.start)
            w.write(entry.end)
        }
        return w.data
    }
}
