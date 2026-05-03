import Testing
import Foundation
@testable import Acervo

@Suite("TextRecord")
struct TextRecordTests {

    @Test func payloadAndTrailAreConcatenated() {
        let trail = TrailingData(multibyte: 0)
        let record = TextRecord(text: Data([0xAA, 0xBB]), trail: trail)
        let bytes = Array(record.encoded())
        // Payload (2 bytes) + trail (TrailingData(0).encoded() = [0x00, 0x81]).
        #expect(bytes == [0xAA, 0xBB, 0x00, 0x81])
    }

    @Test func lengthReportsPayloadPlusTrail() {
        let record = TextRecord(text: Data(count: 100), trail: TrailingData())
        // Payload 100 + trail 2 (multibyte byte + length VWI) = 102.
        #expect(record.length == 102)
    }

    @Test func conformsToPalmDBRecord() {
        let record = TextRecord(text: Data([0x42]), trail: TrailingData())
        let database = PalmDB.Database(name: "T", date: .now, records: [record])
        #expect(database.encoded().count > 0)
    }
}

@Suite("textToRecords")
struct TextToRecordsTests {

    @Test func emptyTextProducesNoRecords() {
        let records = textToRecords(text: Data(), chapters: [])
        #expect(records.isEmpty)
    }

    @Test func textShorterThanMaxFitsInOneRecord() {
        let text = Data(repeating: 0x41, count: 100)
        let records = textToRecords(text: text, chapters: [])
        #expect(records.count == 1)
        #expect(records[0].data.count == 100)
    }

    @Test func textExactlyAtMaxSizeFitsInOneRecord() {
        let text = Data(repeating: 0x41, count: TextRecord.maxSize)
        let records = textToRecords(text: text, chapters: [])
        #expect(records.count == 1)
        #expect(records[0].data.count == TextRecord.maxSize)
    }

    @Test func textJustOverMaxSizeProducesTwoRecords() {
        let text = Data(repeating: 0x41, count: TextRecord.maxSize + 1)
        let records = textToRecords(text: text, chapters: [])
        #expect(records.count == 2)
        #expect(records[0].data.count == TextRecord.maxSize)
        #expect(records[1].data.count == 1)
    }

    @Test func recordsContainCorrectByteSlices() {
        // 12 bytes of text → with maxSize=4096 fits in one record. Use
        // small fake-max math by building a real 4097-byte buffer with
        // recognisable bytes at the boundary.
        var bytes: [UInt8] = []
        for i in 0..<TextRecord.maxSize { bytes.append(UInt8(i & 0xFF)) }
        bytes.append(0xFF) // The 4097th byte.
        let records = textToRecords(text: Data(bytes), chapters: [])
        #expect(records.count == 2)
        // Last byte of record 0 = (4095 & 0xFF) = 0xFF.
        #expect(records[0].data.last == 0xFF)
        // First byte of record 1 = the trailing 0xFF we appended.
        #expect(records[1].data.first == 0xFF)
    }

    @Test func chapterStrandHintIsAttachedPerRecord() {
        // Two chapters each fully inside one 4096-byte boundary.
        let chapters = [
            ChapterInfo(title: "A", start: 0, length: 4096),
            ChapterInfo(title: "B", start: 4096, length: 4096),
        ]
        let text = Data(repeating: 0x20, count: 8192)
        let records = textToRecords(text: text, chapters: chapters)
        #expect(records.count == 2)
        // Each record's trail must include strand bytes (more than the
        // 2-byte minimum payload-of-zero + length-VWI).
        #expect(records[0].trail.count > 2)
        #expect(records[1].trail.count > 2)
    }
}
