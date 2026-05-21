import Foundation
import Testing

@testable import Tomo

@Suite("bookFileSlug")
struct BookFileSlugTests {

    private let stableID = UUID(uuidString: "12345678-90AB-CDEF-1234-567890ABCDEF")!

    @Test func basicAuthorTitleYear() {
        let result = bookFileSlug(
            title: "The Stranger",
            author: "Albert Camus",
            year: 1942,
            ext: "epub",
            id: stableID
        )
        #expect(result == "albert-camus-the-stranger-1942.epub")
    }

    @Test func diacriticsTransliterate() {
        let result = bookFileSlug(
            title: "L'Étranger",
            author: "Camus",
            year: nil,
            ext: "epub",
            id: stableID
        )
        #expect(result == "camus-l-etranger.epub")
    }

    @Test func cjkTransliteratesToAscii() {
        let result = bookFileSlug(
            title: "ノルウェイの森",
            author: "村上春樹",
            year: 1987,
            ext: "epub",
            id: stableID
        )
        // We don't pin the exact transliteration (ICU output can shift across
        // OS versions); we pin the shape: ASCII alphanumerics + hyphens only,
        // year preserved, extension preserved.
        #expect(result.hasSuffix("-1987.epub"))
        let stem = result.dropLast(".epub".count)
        for char in stem {
            #expect(char.isASCII)
            #expect(char.isLetter || char.isNumber || char == "-")
        }
    }

    @Test func missingYearOmitsSuffix() {
        let result = bookFileSlug(
            title: "The Stranger",
            author: "Camus",
            year: nil,
            ext: "epub",
            id: stableID
        )
        #expect(result == "camus-the-stranger.epub")
    }

    @Test func missingAuthorFallsBackToUnknown() {
        let result = bookFileSlug(
            title: "The Stranger",
            author: nil,
            year: 1942,
            ext: "epub",
            id: stableID
        )
        #expect(result == "unknown-the-stranger-1942.epub")
    }

    @Test func emptyAuthorFallsBackToUnknown() {
        let result = bookFileSlug(
            title: "The Stranger",
            author: "   ",
            year: 1942,
            ext: "epub",
            id: stableID
        )
        #expect(result == "unknown-the-stranger-1942.epub")
    }

    @Test func emptyTitleFallsBackToUntitled() {
        let result = bookFileSlug(
            title: "!!!",
            author: "Camus",
            year: 1942,
            ext: "epub",
            id: stableID
        )
        #expect(result == "camus-untitled-1942.epub")
    }

    @Test func allEmptyUsesIdPrefix() {
        let result = bookFileSlug(
            title: "!!!",
            author: nil,
            year: nil,
            ext: "epub",
            id: stableID
        )
        #expect(result == "untitled-12345678.epub")
    }

    @Test func lengthCapTruncates() {
        let longTitle = String(repeating: "stranger", count: 50)  // 400 chars
        let result = bookFileSlug(
            title: longTitle,
            author: "Camus",
            year: 1942,
            ext: "epub",
            id: stableID
        )
        #expect(result.count <= 200)
        #expect(result.hasSuffix(".epub"))
        #expect(!result.hasSuffix("-.epub"))
    }

    @Test func collapsesRunsAndTrimsEdges() {
        let result = bookFileSlug(
            title: "  The   Stranger  !!!",
            author: "  Camus  ",
            year: 1942,
            ext: "epub",
            id: stableID
        )
        #expect(result == "camus-the-stranger-1942.epub")
    }

    @Test func lowercasesExtension() {
        let result = bookFileSlug(
            title: "The Stranger",
            author: "Camus",
            year: 1942,
            ext: "EPUB",
            id: stableID
        )
        #expect(result == "camus-the-stranger-1942.epub")
    }

    @Test func handlesApostrophesAndPunctuation() {
        let result = bookFileSlug(
            title: "Mr. Mercedes",
            author: "Stephen King",
            year: 2014,
            ext: "epub",
            id: stableID
        )
        #expect(result == "stephen-king-mr-mercedes-2014.epub")
    }
}
