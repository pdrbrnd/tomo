import Foundation
import Testing

@testable import Tomo

@Suite("Markup")
struct MarkupTests {

  @Test func emptyChunksProducesEmptyTextAndNoChunks() {
    let manifest = BookManifest(
      title: "T", authors: [], language: "en", chunks: [])
    let (text, chunks, chapters) = Markup.chaptersToText(manifest)
    #expect(text.isEmpty)
    #expect(chunks.isEmpty)
    // One chapter is always emitted (Phase 1 simplification —
    // length is zero when there's no content).
    #expect(chapters.count == 1)
    #expect(chapters[0].length == 0)
  }

  @Test func singleChunkPlacesContentAfterSkeleton() {
    let manifest = BookManifest(
      title: "T", authors: [], language: "en",
      chunks: ["<p>Hi</p>"]
    )
    let (text, chunks, _) = Markup.chaptersToText(manifest)
    // ChunkInfo for the single chunk:
    #expect(chunks.count == 1)
    #expect(chunks[0].preStart == 0)
    #expect(chunks[0].preLength > 0)
    #expect(chunks[0].contentStart == chunks[0].preLength)
    #expect(chunks[0].contentLength == "<p>Hi</p>".utf8.count)
    // Content lands at the declared offset.
    let content = text.subdata(
      in: chunks[0].contentStart..<chunks[0].contentStart + chunks[0].contentLength)
    #expect(String(decoding: content, as: UTF8.self) == "<p>Hi</p>")
  }

  @Test func multipleChunksConcatenateBackToBack() {
    let manifest = BookManifest(
      title: "T", authors: [], language: "en",
      chunks: ["<p>A</p>", "<p>BB</p>", "<p>CCC</p>"]
    )
    let (text, chunks, _) = Markup.chaptersToText(manifest)
    #expect(chunks.count == 3)
    // Each chunk's preStart picks up where the previous chunk's
    // content ended.
    for i in 1..<chunks.count {
      let prevEnd = chunks[i - 1].contentStart + chunks[i - 1].contentLength
      #expect(chunks[i].preStart == prevEnd)
    }
    // Total text length is the sum of all pre+content for all chunks.
    let totalContent = chunks.reduce(0) { $0 + $1.preLength + $1.contentLength }
    #expect(text.count == totalContent)
  }

  @Test func chunkSkeletonContainsTitleAndAID() {
    let manifest = BookManifest(
      title: "Frankenstein", authors: [], language: "en",
      chunks: ["<p>Body</p>"]
    )
    let (text, chunks, _) = Markup.chaptersToText(manifest)
    let skeleton = text.subdata(in: 0..<chunks[0].preLength)
    let s = String(decoding: skeleton, as: UTF8.self)
    #expect(s.contains("<title>Frankenstein</title>"))
    #expect(s.contains("aid=\"0000\""))
  }

  @Test func aidIncrementsPerChunk() {
    let manifest = BookManifest(
      title: "T", authors: [], language: "en",
      chunks: ["<p>A</p>", "<p>B</p>"]
    )
    let (text, chunks, _) = Markup.chaptersToText(manifest)
    // First chunk skeleton — aid="0000"
    let s0 = String(decoding: text.subdata(in: 0..<chunks[0].preLength), as: UTF8.self)
    #expect(s0.contains("aid=\"0000\""))
    // Second chunk skeleton — aid="0001"
    let s1 = String(
      decoding: text.subdata(
        in: chunks[1].preStart..<chunks[1].preStart + chunks[1].preLength
      ), as: UTF8.self)
    #expect(s1.contains("aid=\"0001\""))
  }

  @Test func chapterCoversTotalText() {
    let manifest = BookManifest(
      title: "T", authors: [], language: "en",
      chunks: ["<p>One</p>", "<p>Two</p>"]
    )
    let (text, _, chapters) = Markup.chaptersToText(manifest)
    #expect(chapters.count == 1)
    #expect(chapters[0].start == 0)
    #expect(chapters[0].length == text.count)
  }

  @Test func multibyteUTF8SurvivesRoundTrip() {
    // The byte counts are byte counts, not character counts.
    let manifest = BookManifest(
      title: "Coração", authors: [], language: "pt-PT",
      chunks: ["<p>café</p>"]
    )
    let (text, chunks, _) = Markup.chaptersToText(manifest)
    let content = text.subdata(
      in: chunks[0].contentStart..<chunks[0].contentStart + chunks[0].contentLength)
    #expect(String(decoding: content, as: UTF8.self) == "<p>café</p>")
    // contentLength is byte count, "café" has 5 bytes (é = 2).
    #expect(chunks[0].contentLength == "<p>café</p>".utf8.count)
  }
}
