import Foundation

/// Pure encode/decode for the PTP container format MTP rides on. No I/O —
/// `MTPConnection` moves the bytes; this file only knows their shape, so it
/// can be unit-tested without a device.
///
/// Wire format (all little-endian): a 12-byte header — `length u32`,
/// `type u16`, `code u16`, `transactionID u32` — followed by up to five
/// `u32` params (command/response) or a payload (data).
nonisolated enum PTP {
    static let headerSize = 12

    enum ContainerType: UInt16 {
        case command = 1
        case data = 2
        case response = 3
        case event = 4
    }

    enum Operation: UInt16 {
        case getDeviceInfo = 0x1001
        case openSession = 0x1002
        case closeSession = 0x1003
        case getStorageIDs = 0x1004
        case getObjectHandles = 0x1007
        case getObjectInfo = 0x1008
        case getObject = 0x1009
        case deleteObject = 0x100B
        case sendObjectInfo = 0x100C
        case sendObject = 0x100D
    }

    enum Response {
        static let ok: UInt16 = 0x2001
        static let sessionAlreadyOpen: UInt16 = 0x201E
    }

    enum ObjectFormat {
        static let undefined: UInt16 = 0x3000
        static let association: UInt16 = 0x3001  // a folder
    }

    /// `GetObjectHandles` parent value meaning "the storage root".
    static let rootParent: UInt32 = 0xFFFF_FFFF

    struct Header: Equatable {
        let length: UInt32
        let type: UInt16
        let code: UInt16
        let transactionID: UInt32
    }

    static func command(_ op: Operation, transactionID: UInt32, params: [UInt32] = []) -> Data {
        var out = Data()
        out.appendLE(UInt32(headerSize + 4 * params.count))
        out.appendLE(ContainerType.command.rawValue)
        out.appendLE(op.rawValue)
        out.appendLE(transactionID)
        for p in params { out.appendLE(p) }
        return out
    }

    /// Header for a data phase of `payloadLength` bytes. The payload itself
    /// is streamed separately so large files never sit in memory twice.
    static func dataHeader(_ op: Operation, transactionID: UInt32, payloadLength: Int) -> Data {
        var out = Data()
        out.appendLE(UInt32(clamping: headerSize + payloadLength))
        out.appendLE(ContainerType.data.rawValue)
        out.appendLE(op.rawValue)
        out.appendLE(transactionID)
        return out
    }

    static func parseHeader(_ data: Data) throws(MTPError) -> Header {
        var r = PTPReader(data)
        return Header(
            length: try r.u32(), type: try r.u16(), code: try r.u16(), transactionID: try r.u32())
    }

    /// Params trailing a response container's header.
    static func responseParams(_ container: Data) -> [UInt32] {
        var r = PTPReader(container)
        r.offset = headerSize
        var params: [UInt32] = []
        while let p = try? r.u32() { params.append(p) }
        return params
    }

    /// `GetStorageIDs` / `GetObjectHandles` payload: a `u32` count then that
    /// many `u32`s.
    static func parseUInt32Array(_ data: Data) throws(MTPError) -> [UInt32] {
        var r = PTPReader(data)
        let count = Int(try r.u32())
        // Guard against a garbage count before allocating.
        guard count <= (data.count - 4) / 4 else { throw .malformed("array count \(count)") }
        return try (0..<count).map { _ throws(MTPError) in try r.u32() }
    }

    // MARK: - ObjectInfo

    /// The subset of the PTP ObjectInfo dataset Tomo reads or writes.
    struct ObjectInfo: Equatable {
        var storageID: UInt32
        var format: UInt16
        var size: UInt32
        var parent: UInt32
        var filename: String
        var modified: Date?

        var isFolder: Bool { format == ObjectFormat.association }
    }

    static func encodeObjectInfo(_ info: ObjectInfo) -> Data {
        var out = Data()
        out.appendLE(info.storageID)
        out.appendLE(info.format)
        out.appendLE(UInt16(0))  // protection status
        out.appendLE(info.size)
        out.appendLE(UInt16(0))  // thumb format
        for _ in 0..<6 { out.appendLE(UInt32(0)) }  // thumb size/w/h, image w/h/depth
        out.appendLE(info.parent)
        // Folders are "generic folder" associations; files have none.
        out.appendLE(UInt16(info.isFolder ? 1 : 0))
        out.appendLE(UInt32(0))  // association desc
        out.appendLE(UInt32(0))  // sequence number
        out.append(encodeString(info.filename))
        out.append(encodeString(""))  // capture date
        out.append(encodeString(""))  // modification date
        out.append(encodeString(""))  // keywords
        return out
    }

    static func decodeObjectInfo(_ data: Data) throws(MTPError) -> ObjectInfo {
        var r = PTPReader(data)
        let storageID = try r.u32()
        let format = try r.u16()
        r.offset = 8
        let size = try r.u32()
        r.offset = 38
        let parent = try r.u32()
        r.offset = 52
        let filename = try r.string()
        _ = try? r.string()  // capture date
        let modified = (try? r.string()).flatMap(parseDate)
        return ObjectInfo(
            storageID: storageID, format: format, size: size, parent: parent,
            filename: filename, modified: modified)
    }

    // MARK: - Strings & dates

    /// PTP string: `u8` count of UTF-16 code units *including* the NUL
    /// terminator, then UTF-16LE. Empty string is a single zero byte.
    static func encodeString(_ s: String) -> Data {
        guard !s.isEmpty else { return Data([0]) }
        let units = Array(s.utf16.prefix(254)) + [0]
        var out = Data([UInt8(units.count)])
        for u in units { out.appendLE(u) }
        return out
    }

    /// PTP DateTime: `YYYYMMDDThhmmss`, optionally followed by `.s`, `Z`, or
    /// a `±hhmm` offset. Devices mostly omit the zone; treat that as local.
    static func parseDate(_ s: String) -> Date? {
        let chars = Array(s)
        guard chars.count >= 15, chars[8] == "T" else { return nil }
        func num(_ range: Range<Int>) -> Int? { Int(String(chars[range])) }
        guard let y = num(0..<4), let mo = num(4..<6), let d = num(6..<8),
            let h = num(9..<11), let mi = num(11..<13), let sec = num(13..<15)
        else { return nil }
        let utc = s.hasSuffix("Z")
        var comps = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: sec)
        comps.timeZone = utc ? TimeZone(identifier: "UTC") : .current
        return Calendar(identifier: .gregorian).date(from: comps)
    }
}

/// Bounds-checked little-endian reader. Every read throws on overrun so a
/// short or malformed packet from the device can never trap.
nonisolated struct PTPReader {
    let data: Data
    var offset = 0

    init(_ data: Data) { self.data = data }

    private mutating func bytes(_ n: Int) throws(MTPError) -> Data {
        guard offset >= 0, offset + n <= data.count else {
            throw .malformed("read \(n) bytes at \(offset) of \(data.count)")
        }
        let start = data.startIndex + offset
        offset += n
        return data[start..<start + n]
    }

    mutating func u8() throws(MTPError) -> UInt8 { try bytes(1).first! }

    mutating func u16() throws(MTPError) -> UInt16 {
        let b = try bytes(2)
        return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8
    }

    mutating func u32() throws(MTPError) -> UInt32 {
        let lo = UInt32(try u16())
        return lo | UInt32(try u16()) << 16
    }

    mutating func string() throws(MTPError) -> String {
        let count = Int(try u8())
        guard count > 0 else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for _ in 0..<count { units.append(try u16()) }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
}

extension Data {
    nonisolated mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
