import Foundation

/// A TAGX tag — a 32-bit value packing four metadata fields used to
/// describe one column of an INDX entry. Big-endian byte layout:
///
///   byte 0  tagId
///   byte 1  tagNum     (number of values per entry, denominator for nentries)
///   byte 2  bitmask    (where this tag's bits live in the control byte)
///   byte 3  endMarker  (1 = end-of-table sentinel, 0 = regular tag)
///
/// The constants below are taken straight from leotaku/mobi's
/// `types/exth.go`. Values that look duplicated (e.g. `entryPosition`
/// and `guideTitle` both `0x01010100`) are intentional — semantically
/// distinct fields whose binary representation collides because they
/// occupy the same column in different tables.
nonisolated struct TAGXTag: Hashable, Sendable {
    let raw: UInt32

    init(_ raw: UInt32) { self.raw = raw }

    var tagId: UInt8     { UInt8((raw >> 24) & 0xFF) }
    var tagNum: UInt8    { UInt8((raw >> 16) & 0xFF) }
    var bitmask: UInt8   { UInt8((raw >> 8) & 0xFF) }
    var endMarker: UInt8 { UInt8(raw & 0xFF) }
    var isEnd: Bool      { endMarker == 1 }

    // NCX entries (flat — hierarchical fields are added when v2 needs them)
    static let entryPosition    = TAGXTag(0x01010100)
    static let entryLength      = TAGXTag(0x02010200)
    static let entryNameOffset  = TAGXTag(0x03010400)
    static let entryDepthLevel  = TAGXTag(0x04010800)

    // Skeleton table
    static let skeletonChunkCount = TAGXTag(0x01010300)
    static let skeletonGeometry   = TAGXTag(0x06020C00)

    // Chunk table
    static let chunkCNCXOffset     = TAGXTag(0x02010100)
    static let chunkFileNumber     = TAGXTag(0x03010200)
    static let chunkSequenceNumber = TAGXTag(0x04010400)
    static let chunkGeometry       = TAGXTag(0x06020800)

    /// End-of-table sentinel — required at the end of every TAGX table.
    static let end = TAGXTag(0x00000001)
}

/// Tag tables used by the canonical AZW3 INDX records. Each must end
/// with `.end` — `calculateControlByte` will trip a precondition
/// otherwise.
nonisolated enum TAGXTable {
    static let ncxSingle: [TAGXTag] = [
        .entryPosition,
        .entryLength,
        .entryNameOffset,
        .entryDepthLevel,
        .end,
    ]

    static let skeleton: [TAGXTag] = [
        .skeletonChunkCount,
        .skeletonGeometry,
        .end,
    ]

    static let chunk: [TAGXTag] = [
        .chunkCNCXOffset,
        .chunkFileNumber,
        .chunkSequenceNumber,
        .chunkGeometry,
        .end,
    ]
}

/// Number of values one of these tag columns claims for itself —
/// values not encoded in the tag's binary representation but baked
/// into the spec.
nonisolated func nvals(for tag: TAGXTag) -> UInt8 {
    switch tag {
    case .skeletonGeometry:                     return 4
    case .chunkGeometry, .skeletonChunkCount:   return 2
    default:                                    return 1
    }
}

/// Computes the single control byte that prefixes each INDX entry,
/// summarising which TAGX columns carry data and how many values each
/// has. Direct port of leotaku/mobi's `calculateControlByte`.
///
/// The math: each non-end tag contributes `bitmask & (nentries << shifts)`
/// to the running total, where `nentries = nvals / tagNum` and
/// `shifts = bitmask.trailingZeroBitCount`. End markers flush the
/// accumulator into the output list. Multiple end markers produce
/// multiple control bytes; we return the first (matches leotaku, and
/// every table we use only has one).
nonisolated func calculateControlByte(_ tags: [TAGXTag]) -> UInt8 {
    var controlBytes: [UInt8] = []
    var current: UInt8 = 0
    for tag in tags {
        if tag.isEnd {
            controlBytes.append(current)
            current = 0
            continue
        }
        let n = nvals(for: tag)
        let nentries = n / tag.tagNum
        let shifts = UInt32(tag.bitmask.trailingZeroBitCount)
        let shifted = UInt32(nentries) << shifts
        current |= tag.bitmask & UInt8(shifted & 0xFF)
    }
    precondition(!controlBytes.isEmpty,
        "TAGX table must contain at least one .end marker")
    return controlBytes[0]
}
