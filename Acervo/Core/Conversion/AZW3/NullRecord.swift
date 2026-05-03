import Foundation

/// Record 0 of every AZW3 file — the "Null record" or "header record."
/// Bundles the PalmDoc header, KF8 header, EXTH metadata section, the
/// book's full name, and 8 KB of trailing zero padding.
///
/// Layout:
///
///   [16]   PalmDoc header
///   [264]  KF8 header
///   [...]  EXTH section (with internal 4-byte alignment padding)
///   [N]    Full name as UTF-8 bytes
///   [8192] Zero padding
///
/// The KF8 header's `fullNameOffset` and `fullNameLength` fields are
/// computed at serialisation time — the EXTH section's length isn't
/// known until its entries are populated.
nonisolated struct NullRecord: PalmDB.Record {
    static let trailingPaddingLength = 8192

    var palmDoc: PalmDocHeader = PalmDocHeader()
    var mobi: KF8Header = KF8Header()
    var exth: EXTHSection = EXTHSection()
    var fullName: String

    init(fullName: String) {
        self.fullName = fullName
    }

    func encoded() -> Data {
        let nameBytes = Data(fullName.utf8)
        let nameOffset = PalmDocHeader.length + KF8Header.length + exth.length

        // Local copy — encoding shouldn't visibly mutate the caller's
        // record; both fields would be wrong on a second `encoded()`
        // call if we mutated in place.
        var mobi = self.mobi
        mobi.fullNameOffset = UInt32(nameOffset)
        mobi.fullNameLength = UInt32(nameBytes.count)

        let totalSize = nameOffset + nameBytes.count + Self.trailingPaddingLength
        var w = BinaryWriter(reservingCapacity: totalSize)
        w.write(palmDoc.encoded())
        w.write(mobi.encoded())
        w.write(exth.encoded())
        w.write(nameBytes)
        w.writeZeros(Self.trailingPaddingLength)
        return w.data
    }
}
