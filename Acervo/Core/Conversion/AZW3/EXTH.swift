import Foundation

/// EXTH entry type codes that Acervo emits. Each value is the
/// reverse-engineered code Kindle firmware looks for. Add cases as new
/// metadata fields land — the spec defines ~60 codes; we only need
/// what's actually written.
///
/// Reference: https://wiki.mobileread.com/wiki/MOBI#EXTH_Header
nonisolated enum EXTHEntryType: UInt32, Sendable {
    case title = 99
    case author = 100
    case publisher = 101
    /// BCP 47 language tag. Modern Kindles read this; older
    /// ones fall back to the MOBIHeader.Locale field.
    case language = 524
}

/// One EXTH entry: 8-byte header (type + total length) followed by the
/// payload bytes. UTF-8 for strings; big-endian uint32 for integers.
nonisolated struct EXTHEntry: Sendable {
    let type: EXTHEntryType
    let data: Data

    /// Total bytes when serialised — the 8-byte header plus the payload.
    /// EXTH parsers use this to skip past entries they don't recognise.
    var length: Int { 8 + data.count }

    func encoded() -> Data {
        var w = BinaryWriter(reservingCapacity: length)
        w.write(type.rawValue)
        w.write(UInt32(length))
        w.write(data)
        return w.data
    }
}

/// EXTH section — the metadata block inside the Null record. Layout:
///
///   [4]  "EXTH"
///   [4]  Header+entries length (excludes trailing padding)
///   [4]  Entry count
///   [N]  Entries, back-to-back
///   [P]  Zero padding so the section ends on a 4-byte boundary
///
/// The header length field deliberately *excludes* the padding so
/// readers can walk to the last entry without reading garbage.
nonisolated struct EXTHSection: Sendable {
    static let headerLength = 12

    private(set) var entries: [EXTHEntry] = []

    init() {}

    mutating func add(_ type: EXTHEntryType, string: String) {
        guard !string.isEmpty else { return }
        entries.append(EXTHEntry(type: type, data: Data(string.utf8)))
    }

    mutating func add(_ type: EXTHEntryType, integer: UInt32) {
        var w = BinaryWriter(reservingCapacity: 4)
        w.write(integer)
        entries.append(EXTHEntry(type: type, data: w.data))
    }

    /// Length of the header + entries, *not* including the trailing
    /// padding. This is the value that goes into the EXTH header's
    /// length field.
    var lengthWithoutPadding: Int {
        Self.headerLength + entries.reduce(0) { $0 + $1.length }
    }

    /// Bytes of zero padding needed to round `lengthWithoutPadding` up
    /// to a 4-byte boundary.
    var paddingByteCount: Int {
        let remainder = lengthWithoutPadding % 4
        return remainder == 0 ? 0 : 4 - remainder
    }

    /// Total bytes the section occupies inside the Null record,
    /// including padding. Callers placing the FullName string after
    /// the EXTH use this to compute the FullNameOffset.
    var length: Int {
        lengthWithoutPadding + paddingByteCount
    }

    func encoded() -> Data {
        var w = BinaryWriter(reservingCapacity: length)
        w.writeMagic("EXTH")
        w.write(UInt32(lengthWithoutPadding))
        w.write(UInt32(entries.count))
        for entry in entries {
            w.write(entry.encoded())
        }
        w.writeZeros(paddingByteCount)
        return w.data
    }
}
