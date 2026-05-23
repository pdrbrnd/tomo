import Foundation
import Testing

@testable import Tomo

@MainActor
@Suite("QueryParser")
struct QueryParserTests {

    @Test func bareISBN13Extracted() {
        let q = QueryParser.parse("9780140449136")
        #expect(q.isbn == "9780140449136")
        #expect(q.text.isEmpty)
    }

    @Test func hyphenatedISBN13Extracted() {
        let q = QueryParser.parse("978-0-14-044913-6")
        #expect(q.isbn == "9780140449136")
        #expect(q.text.isEmpty)
    }

    @Test func isbn13MixedWithFreeText() {
        let q = QueryParser.parse("9780140449136 dostoevsky")
        #expect(q.isbn == "9780140449136")
        #expect(q.text == "dostoevsky")
    }

    @Test func validISBN10Extracted() {
        // 0140449132 is a real Penguin Classics ISBN-10 with valid checksum.
        let q = QueryParser.parse("0140449132")
        #expect(q.isbn == "0140449132")
        #expect(q.text.isEmpty)
    }

    @Test func isbn10WithXCheckDigit() {
        // 020161622X — Knuth, TAOCP vol 1. Valid checksum with X.
        let q = QueryParser.parse("020161622X")
        #expect(q.isbn == "020161622X")
    }

    @Test func isbn10LowercaseXAcceptedAndNormalized() {
        let q = QueryParser.parse("020161622x")
        #expect(q.isbn == "020161622X")
    }

    @Test func tenDigitNumberWithBadChecksumFallsThrough() {
        let q = QueryParser.parse("1234567890")
        #expect(q.isbn == nil)
        #expect(q.text == "1234567890")
    }

    @Test func thirteenDigitNumberWithBadChecksumFallsThrough() {
        let q = QueryParser.parse("9999999999999")
        #expect(q.isbn == nil)
        #expect(q.text == "9999999999999")
    }

    @Test func thirteenDigitNumberWithoutISBNPrefixFallsThrough() {
        // 1234567890123 isn't 978/979-prefixed — even if checksum happened
        // to pass, it's not an ISBN-13. Treat as text.
        let q = QueryParser.parse("1234567890123")
        #expect(q.isbn == nil)
        #expect(q.text == "1234567890123")
    }

    @Test func explicitISBNFieldStillWorks() {
        let q = QueryParser.parse("isbn:9780140449136 dostoevsky")
        #expect(q.isbn == "9780140449136")
        #expect(q.text == "dostoevsky")
    }

    @Test func secondISBNFallsToText() {
        // First valid ISBN wins; a second valid ISBN drops to free text.
        // Rare in real use; keeping this simple.
        let q = QueryParser.parse("9780140449136 0140449132")
        #expect(q.isbn == "9780140449136")
        #expect(q.text == "0140449132")
    }

    @Test func nonISBNTokensUnaffected() {
        let q = QueryParser.parse("ensaio sobre author:saramago language:pt")
        #expect(q.isbn == nil)
        #expect(q.text == "ensaio sobre")
        #expect(q.author == "saramago")
        #expect(q.language == "pt")
    }
}
