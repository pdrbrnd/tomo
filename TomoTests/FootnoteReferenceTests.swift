import Foundation
import Testing

@testable import Tomo

@Suite("isFootnoteReference")
struct FootnoteReferenceTests {

    /// Parses an XHTML body fragment through the production path and returns its
    /// first `<a>` element, preserving parent context (for `<sup>` wrapper cases).
    private func anchor(in bodyHTML: String) -> XMLElement {
        let doc = """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" \
            xmlns:epub="http://www.idpf.org/2007/ops">\
            <body>\(bodyHTML)</body></html>
            """
        let parsed = parseXHTMLOrTidy(Data(doc.utf8))!
        return (try! parsed.nodes(forXPath: "//*[local-name()='a']")).first as! XMLElement
    }

    @Test func detectsEpubTypeNoteref() {
        #expect(isFootnoteReference(anchor(in: ##"<a epub:type="noteref" href="#fn1">1</a>"##)))
    }

    @Test func detectsRoleDocNoteref() {
        #expect(isFootnoteReference(anchor(in: ##"<a role="doc-noteref" href="#fn1">note</a>"##)))
    }

    @Test func detectsSupWrappedAnchor() {
        #expect(isFootnoteReference(anchor(in: ##"<sup><a href="#fn1">3</a></sup>"##)))
    }

    @Test func detectsAnchorContainingSup() {
        #expect(isFootnoteReference(anchor(in: ##"<a href="#fn1"><sup>3</sup></a>"##)))
    }

    @Test func detectsBareNumericMarker() {
        #expect(isFootnoteReference(anchor(in: ##"<a href="#fn1">12</a>"##)))
    }

    @Test func detectsBracketedMarker() {
        #expect(isFootnoteReference(anchor(in: ##"<a href="#fn1">[1]</a>"##)))
    }

    @Test func detectsSymbolMarker() {
        #expect(isFootnoteReference(anchor(in: ##"<a href="#fn1">*</a>"##)))
    }

    @Test func ignoresProseCrossReference() {
        #expect(!isFootnoteReference(anchor(in: ##"<a href="#sec3">see Chapter 3</a>"##)))
    }

    @Test func ignoresChapterLink() {
        #expect(!isFootnoteReference(anchor(in: ##"<a href="#ch-3">Introduction</a>"##)))
    }
}
