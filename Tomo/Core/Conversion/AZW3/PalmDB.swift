import Foundation

/// PalmDB container format — the outermost binary frame of every AZW3 file.
/// Every record (PalmDoc text, MOBI/KF8 headers, INDX, FDST, etc.) sits
/// inside this container. The format is reverse-engineered; the canonical
/// reference is the MobileRead Wiki (https://wiki.mobileread.com/wiki/PDB),
/// cross-checked against leotaku/mobi (Go, MIT) for byte layout details.
///
/// Byte layout produced by `PalmDB.Database.encoded()`:
///
///   [78-byte PalmDB header]
///   [8-byte record header] × N
///   [2-byte zero padding]
///   [record bodies, concatenated, in declaration order]
nonisolated enum PalmDB {

    /// One record inside a PalmDB. Conformers produce their own
    /// concatenated byte representation; the database wraps them with
    /// offsets, IDs, and the file header.
    nonisolated protocol Record: Sendable {
        func encoded() -> Data
    }

    /// Pre-built record carrying a fixed byte payload. Used for things
    /// like compressed text records or images that are produced
    /// elsewhere and slotted in.
    nonisolated struct RawRecord: Record {
        let payload: Data
        init(_ payload: Data) { self.payload = payload }
        func encoded() -> Data { payload }
    }

    /// In-memory PalmDB ready to serialise.
    nonisolated struct Database: Sendable {
        var name: String
        var date: Date
        var records: [any Record]

        init(name: String, date: Date = .now, records: [any Record] = []) {
            self.name = name
            self.date = date
            self.records = records
        }

        /// Encodes the full PalmDB to bytes. Mirrors the layout written by
        /// leotaku/mobi's `pdb.Database.Write`.
        func encoded() -> Data {
            precondition(
                records.count <= Int(UInt16.max),
                "PalmDB supports at most \(UInt16.max) records (got \(records.count))")

            let recordCount = records.count
            let palmTime = UInt32(palmEpochSeconds: date)
            // Calibre / leotaku double the per-record UID, and the
            // header reports the *last* UID, hence (n*2 - 1). For an
            // empty database the unsigned subtraction wraps to
            // UInt32.max — matches leotaku/mobi byte-for-byte. An empty
            // database isn't a useful book, but staying byte-identical
            // makes diffing against the Go reference simpler.
            let lastRecordUID = UInt32(recordCount * 2) &- 1

            // Record bodies are emitted into a side buffer first so we
            // know each body's offset before writing the headers above
            // them.
            let palmDBHeaderLength = 78
            let recordHeaderLength = 8
            let initialOffset =
                palmDBHeaderLength
                + recordHeaderLength * recordCount
                + 2  // 2-byte padding between record headers and bodies

            var bodies = Data()
            var offsets: [UInt32] = []
            offsets.reserveCapacity(recordCount)
            for record in records {
                offsets.append(UInt32(initialOffset + bodies.count))
                bodies.append(record.encoded())
            }

            var writer = BinaryWriter(
                reservingCapacity: initialOffset + bodies.count)

            // PalmDB header — 78 bytes, big-endian throughout.
            writer.writeFixedString(name, width: 32)
            writer.write(UInt16(0))  // FileAttributes
            writer.write(UInt16(0))  // Version
            writer.write(palmTime)  // CreationTime
            writer.write(palmTime)  // ModificationTime
            writer.write(palmTime)  // BackupTime
            writer.write(UInt32(0))  // ModificationNumber
            writer.write(UInt32(0))  // AppInfo
            writer.write(UInt32(0))  // SortInfo
            writer.writeMagic("BOOK")  // Type
            writer.writeMagic("MOBI")  // Creator
            writer.write(lastRecordUID)  // LastRecordUID
            writer.write(UInt32(0))  // NextRecordList
            writer.write(UInt16(recordCount))  // NumRecords

            // Record headers — 8 bytes each.
            for (index, offset) in offsets.enumerated() {
                writer.write(offset)  // Offset
                writer.write(UInt8(0))  // Attribute
                writer.write(UInt8(0))  // Skip
                writer.write(UInt16(index * 2))  // UniqueID
            }

            writer.writeZeros(2)
            writer.write(bodies)
            return writer.data
        }
    }
}

private extension UInt32 {
    /// Seconds since the Mac/PalmDB epoch (1904-01-01 00:00:00 UTC).
    /// Saturates on overflow — dates after 2040 produce UInt32.max,
    /// dates before 1904 produce 0. The PalmDB format only has 32 bits
    /// for time and we don't aim to be correct outside its representable
    /// range.
    nonisolated init(palmEpochSeconds date: Date) {
        // Seconds between 1904-01-01 and 1970-01-01 (Unix epoch).
        let unixToPalmOffset: TimeInterval = 2_082_844_800
        let seconds = date.timeIntervalSince1970 + unixToPalmOffset
        self = UInt32(clamping: Int(seconds.rounded()))
    }
}
