import Foundation

/// Small fixed-format records that close out the AZW3 file. All three
/// are essentially magic numbers with one or two variable fields —
/// reverse-engineered from Calibre output, not officially documented.
/// Kindle firmware looks for them by name and will refuse the book if
/// any are missing.

/// FLIS record — 36 bytes of mostly-magic numbers indicating "flow
/// information" (whatever that means in practice; the values come
/// from Calibre and Kindle just expects them).
nonisolated struct FLISRecord: PalmDB.Record {
    static let length = 36

    func encoded() -> Data {
        var w = BinaryWriter(reservingCapacity: Self.length)
        w.writeMagic("FLIS")
        w.write(UInt32(8))             // Fixed1
        w.write(UInt16(65))            // Fixed2
        w.write(UInt16(0))             // Fixed3
        w.write(UInt32(0))             // Fixed4
        w.write(UInt32.max)            // Fixed5
        w.write(UInt16(1))             // Fixed6
        w.write(UInt16(3))             // Fixed7
        w.write(UInt32(3))             // Fixed8
        w.write(UInt32(1))             // Fixed9
        w.write(UInt32.max)            // Fixed10
        return w.data
    }
}

/// FCIS record — 52 bytes. Carries the total text length; everything
/// else is fixed magic. The text length tells Kindle how many bytes of
/// decompressed text to expect across all text records combined.
nonisolated struct FCISRecord: PalmDB.Record {
    static let length = 52

    let textLength: UInt32

    init(textLength: UInt32) {
        self.textLength = textLength
    }

    func encoded() -> Data {
        var w = BinaryWriter(reservingCapacity: Self.length)
        w.writeMagic("FCIS")
        w.write(UInt32(20))            // Fixed1
        w.write(UInt32(16))            // Fixed2
        w.write(UInt32(2))             // Fixed3
        w.write(UInt32(0))             // Fixed4
        w.write(textLength)            // TextLength
        w.write(UInt32(0))             // Fixed5
        w.write(UInt32(40))            // Fixed6
        w.write(UInt32(0))             // Fixed7
        w.write(UInt32(40))            // Fixed8
        w.write(UInt32(8))             // Fixed9
        w.write(UInt16(1))             // Fixed10
        w.write(UInt16(1))             // Fixed11
        w.write(UInt32(0))             // Fixed12
        return w.data
    }
}

/// End-of-file marker — a 4-byte record that tells parsers the PalmDB
/// stream is done. Magic bytes from Calibre output: 0xE9 0x8E 0x0D 0x0A.
nonisolated struct EOFRecord: PalmDB.Record {
    static let length = 4

    func encoded() -> Data {
        Data([0xE9, 0x8E, 0x0D, 0x0A])
    }
}
