import Foundation
import Testing

@testable import Tomo

@Suite("EPUBArchive.resolvePath")
struct EPUBArchivePathTests {

    @Test func combinesRelativeHrefWithBaseDir() {
        #expect(EPUBArchive.resolvePath("ch1.xhtml", baseDir: "OEBPS") == "OEBPS/ch1.xhtml")
    }

    @Test func emptyBaseDirReturnsHrefAsIs() {
        #expect(EPUBArchive.resolvePath("ch1.xhtml", baseDir: "") == "ch1.xhtml")
    }

    @Test func stripsFragment() {
        #expect(
            EPUBArchive.resolvePath("ch1.xhtml#section-2", baseDir: "OEBPS") == "OEBPS/ch1.xhtml")
    }

    @Test func percentDecodesHref() {
        #expect(
            EPUBArchive.resolvePath("My%20Book.xhtml", baseDir: "OEBPS") == "OEBPS/My Book.xhtml")
    }

    @Test func resolvesParentTraversal() {
        #expect(
            EPUBArchive.resolvePath("../images/cover.jpg", baseDir: "OEBPS/Text")
                == "OEBPS/images/cover.jpg")
    }

    @Test func resolvesCurrentDirSegment() {
        #expect(EPUBArchive.resolvePath("./ch1.xhtml", baseDir: "OEBPS") == "OEBPS/ch1.xhtml")
    }

    @Test func resolvesMultipleParentSegments() {
        #expect(
            EPUBArchive.resolvePath("../../style.css", baseDir: "OEBPS/Text/sub") == "OEBPS/style.css")
    }

    @Test func clampsParentTraversalAtRoot() {
        // `..` past the root has nothing to pop — the segment is dropped.
        #expect(EPUBArchive.resolvePath("../../../oops.css", baseDir: "OEBPS") == "oops.css")
    }

    @Test func handlesFragmentAndPercentEncodingTogether() {
        #expect(
            EPUBArchive.resolvePath("My%20Book.xhtml#chapter", baseDir: "OEBPS")
                == "OEBPS/My Book.xhtml")
    }

    @Test func collapsesDoubleSlashesViaEmptySubsequenceFiltering() {
        #expect(
            EPUBArchive.resolvePath("Text//ch1.xhtml", baseDir: "OEBPS") == "OEBPS/Text/ch1.xhtml")
    }
}
