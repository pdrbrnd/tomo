import Foundation
import JavaScriptCore
import Testing

@testable import Tomo

@Suite("PluginManifest")
@MainActor
struct PluginManifestTests {

    @Test func extractsAllFieldsFromCompleteManifest() {
        let ctx = JSContext()!
        ctx.evaluateScript(
            """
            const manifest = {
              id: "gutenberg",
              name: "Project Gutenberg",
              description: "Public-domain books.",
              homepage: "https://www.gutenberg.org",
              author: "Tomo",
              license: "MIT",
              minAppVersion: "1.6.0",
            };
            """
        )
        let m = PluginManifest.from(jsContext: ctx)
        #expect(m?.id == "gutenberg")
        #expect(m?.name == "Project Gutenberg")
        #expect(m?.description == "Public-domain books.")
        #expect(m?.homepage?.absoluteString == "https://www.gutenberg.org")
        #expect(m?.author == "Tomo")
        #expect(m?.license == "MIT")
        #expect(m?.minAppVersion == "1.6.0")
    }

    @Test func nameFallsBackToIDWhenAbsent() {
        let ctx = JSContext()!
        ctx.evaluateScript("const manifest = { id: \"x\" };")
        let m = PluginManifest.from(jsContext: ctx)
        #expect(m?.id == "x")
        #expect(m?.name == "x")
    }

    @Test func returnsNilWhenManifestMissing() {
        let ctx = JSContext()!
        // No manifest declared — common case for legacy plugins.
        ctx.evaluateScript("async function search() { return []; }")
        #expect(PluginManifest.from(jsContext: ctx) == nil)
    }

    @Test func returnsNilWhenManifestNotAnObject() {
        let ctx = JSContext()!
        ctx.evaluateScript("const manifest = \"not an object\";")
        #expect(PluginManifest.from(jsContext: ctx) == nil)
    }

    @Test func returnsNilWhenIDMissing() {
        let ctx = JSContext()!
        ctx.evaluateScript("const manifest = { name: \"X\" };")
        #expect(PluginManifest.from(jsContext: ctx) == nil)
    }

    @Test func optionalFieldsAreNilWhenAbsent() {
        let ctx = JSContext()!
        ctx.evaluateScript("const manifest = { id: \"x\" };")
        let m = PluginManifest.from(jsContext: ctx)
        #expect(m?.description == nil)
        #expect(m?.homepage == nil)
        #expect(m?.author == nil)
        #expect(m?.license == nil)
        #expect(m?.minAppVersion == nil)
    }
}

@Suite("SemVerCompare")
struct SemVerCompareTests {

    @Test func detectsUpgrade() {
        #expect(SemVerCompare.compare("1.0.0", "1.0.1") == .orderedAscending)
        #expect(SemVerCompare.compare("1.0.0", "1.1.0") == .orderedAscending)
        #expect(SemVerCompare.compare("1.0.0", "2.0.0") == .orderedAscending)
    }

    @Test func detectsDowngrade() {
        #expect(SemVerCompare.compare("2.0.0", "1.9.9") == .orderedDescending)
    }

    @Test func equalVersions() {
        #expect(SemVerCompare.compare("1.0.0", "1.0.0") == .orderedSame)
        #expect(SemVerCompare.compare("1.0", "1.0.0") == .orderedSame)
        #expect(SemVerCompare.compare("1", "1.0.0") == .orderedSame)
    }

    @Test func handlesMissingSegmentsAsZero() {
        #expect(SemVerCompare.compare("1.0", "1.0.1") == .orderedAscending)
        #expect(SemVerCompare.compare("1.1", "1.0.5") == .orderedDescending)
    }
}
