import Foundation
import Testing

@testable import Tomo

@Suite("PTP encoding")
struct PTPTests {

    @Test func commandContainerLayout() {
        let bytes = [UInt8](PTP.command(.getObjectHandles, transactionID: 7, params: [0x0001_0001, 0, 0xFFFF_FFFF]))
        #expect(bytes.count == 24)
        #expect(bytes[0..<4] == [24, 0, 0, 0])  // length
        #expect(bytes[4..<6] == [1, 0])  // command
        #expect(bytes[6..<8] == [0x07, 0x10])  // 0x1007
        #expect(bytes[8..<12] == [7, 0, 0, 0])
        #expect(bytes[12..<16] == [0x01, 0x00, 0x01, 0x00])
        #expect(bytes[20..<24] == [0xFF, 0xFF, 0xFF, 0xFF])
    }

    @Test func dataHeaderCountsPayload() throws {
        let header = try PTP.parseHeader(PTP.dataHeader(.sendObject, transactionID: 3, payloadLength: 500))
        #expect(header == PTP.Header(length: 512, type: 2, code: 0x100D, transactionID: 3))
    }

    @Test func responseParamsFollowHeader() {
        var container = PTP.command(.sendObjectInfo, transactionID: 1, params: [0x0001_0001, 0xB55, 0xD97])
        container[4] = 3  // retype as a response
        #expect(PTP.responseParams(container) == [0x0001_0001, 0xB55, 0xD97])
    }

    @Test func uint32ArrayRoundTrip() throws {
        var data = Data()
        for v: UInt32 in [2, 0x90F, 0xB55] { data.appendLE(v) }
        #expect(try PTP.parseUInt32Array(data) == [0x90F, 0xB55])
    }

    @Test func uint32ArrayRejectsOverlongCount() {
        var data = Data()
        data.appendLE(UInt32(1000))
        data.appendLE(UInt32(1))
        #expect(throws: MTPError.self) { try PTP.parseUInt32Array(data) }
    }

    @Test func stringRoundTripIncludingNonASCII() throws {
        let encoded = PTP.encodeString("Pessoa — Livro do Desassossego.azw3")
        var reader = PTPReader(encoded)
        #expect(try reader.string() == "Pessoa — Livro do Desassossego.azw3")
        #expect(reader.offset == encoded.count)
    }

    @Test func emptyStringIsSingleZeroByte() throws {
        #expect(PTP.encodeString("") == Data([0]))
        var reader = PTPReader(Data([0]))
        #expect(try reader.string() == "")
    }

    @Test func objectInfoRoundTrip() throws {
        let info = PTP.ObjectInfo(
            storageID: 0x0001_0001, format: PTP.ObjectFormat.undefined, size: 123_456,
            parent: 0xB55, filename: "author-title-2001.azw3", modified: nil)
        let decoded = try PTP.decodeObjectInfo(PTP.encodeObjectInfo(info))
        #expect(decoded == info)
        #expect(!decoded.isFolder)
    }

    /// The filename sits at a fixed offset (52) in the dataset — devices
    /// reject SendObjectInfo if any field before it is the wrong width.
    @Test func objectInfoFilenameOffset() {
        let encoded = PTP.encodeObjectInfo(
            PTP.ObjectInfo(storageID: 1, format: 0x3000, size: 1, parent: 2, filename: "a", modified: nil))
        #expect(encoded[52] == 2)  // "a" + NUL
        #expect(encoded[53] == UInt8(ascii: "a"))
    }

    @Test func truncatedObjectInfoThrowsInsteadOfTrapping() {
        #expect(throws: MTPError.self) { try PTP.decodeObjectInfo(Data(count: 20)) }
        #expect(throws: MTPError.self) { try PTP.parseHeader(Data()) }
    }

    @Test func parsesDeviceDates() throws {
        let local = try #require(PTP.parseDate("20261114T143005"))
        let comps = Calendar(identifier: .gregorian).dateComponents(
            in: .current, from: local)
        #expect(comps.year == 2026 && comps.month == 11 && comps.day == 14)
        #expect(comps.hour == 14 && comps.minute == 30 && comps.second == 5)

        let utc = try #require(PTP.parseDate("20261114T143005.0Z"))
        #expect(utc.timeIntervalSince1970 == 1_794_666_605)

        #expect(PTP.parseDate("") == nil)
        #expect(PTP.parseDate("garbage-date-str") == nil)
    }
}
