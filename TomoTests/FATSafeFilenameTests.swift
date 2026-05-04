import Foundation
import Testing

@testable import Tomo

@Suite("fatSafeFilename")
struct FATSafeFilenameTests {

    @Test func passesThroughSafeASCII() {
        #expect(fatSafeFilename("Frankenstein.epub") == "Frankenstein.epub")
    }

    @Test func replacesIllegalCharsWithUnderscore() {
        // FAT/exFAT illegal: <>:"/\|?*
        #expect(fatSafeFilename("a<b>c.epub") == "a_b_c.epub")
        #expect(fatSafeFilename("a:b\"c.epub") == "a_b_c.epub")
        #expect(fatSafeFilename(#"a/b\c.epub"#) == "a_b_c.epub")
        #expect(fatSafeFilename("a|b?c*.epub") == "a_b_c_.epub")
    }

    @Test func replacesControlCharactersBelow0x20() {
        let raw = "a\u{0001}b\u{001F}c.epub"
        #expect(fatSafeFilename(raw) == "a_b_c.epub")
    }

    @Test func keepsHigherUnicode() {
        // Accented / non-ASCII chars are valid on FAT32 LFN (UCS-2). Don't strip them.
        #expect(fatSafeFilename("Crônica.epub") == "Crônica.epub")
        #expect(fatSafeFilename("日本語.epub") == "日本語.epub")
    }

    @Test func truncatesLongNamesPreservingExtension() {
        let stem = String(repeating: "a", count: 250)
        let result = fatSafeFilename(stem + ".epub")
        #expect(result.count <= 200)
        #expect(result.hasSuffix(".epub"))
    }

    @Test func truncatesLongStemsWithoutExtension() {
        let raw = String(repeating: "a", count: 250)
        let result = fatSafeFilename(raw)
        #expect(result.count <= 200)
    }

    @Test func keepsShortNamesUnchangedAtBoundary() {
        let exactly200 = String(repeating: "a", count: 195) + ".epub"  // 200 chars
        #expect(fatSafeFilename(exactly200) == exactly200)
    }
}
