import Foundation
import Testing

@testable import Tomo

@Suite("PluginRegistry")
struct PluginRegistryTests {

    @Test func decodesValidRegistryJSON() throws {
        let json = """
            {
              "version": 1,
              "name": "Tomo Official Plugins",
              "plugins": [
                {
                  "id": "gutenberg",
                  "name": "Project Gutenberg",
                  "version": "2026-05-23T16:38:00Z",
                  "description": "Public-domain books.",
                  "homepage": "https://www.gutenberg.org",
                  "author": "Tomo",
                  "license": "MIT",
                  "minAppVersion": "1.7.0",
                  "url": "https://example.com/gutenberg.js",
                  "sha256": "abc123"
                }
              ]
            }
            """
        let file = try JSONDecoder().decode(
            PluginRegistryFile.self, from: Data(json.utf8))
        #expect(file.version == 1)
        #expect(file.plugins.count == 1)
        let entry = file.plugins[0]
        #expect(entry.id == "gutenberg")
        #expect(entry.version == "2026-05-23T16:38:00Z")
        #expect(entry.minAppVersion == "1.7.0")
        #expect(entry.sha256 == "abc123")
    }

    @Test func decodesEntryWithoutOptionalFields() throws {
        let json = """
            {
              "version": 1,
              "name": "Minimal",
              "plugins": [
                {
                  "id": "x",
                  "name": "X",
                  "version": "2026-01-01T00:00:00Z",
                  "url": "https://example.com/x.js",
                  "sha256": "deadbeef"
                }
              ]
            }
            """
        let file = try JSONDecoder().decode(
            PluginRegistryFile.self, from: Data(json.utf8))
        let entry = file.plugins[0]
        #expect(entry.description == nil)
        #expect(entry.homepage == nil)
        #expect(entry.author == nil)
        #expect(entry.license == nil)
        #expect(entry.minAppVersion == nil)
    }

    @Test func cachedRegistryRoundTrip() throws {
        let entry = PluginRegistryEntry(
            id: "x", name: "X",
            version: "2026-05-23T16:38:00Z",
            description: nil, homepage: nil, author: nil, license: nil,
            minAppVersion: "1.7.0",
            url: URL(string: "https://example.com/x.js")!,
            sha256: "deadbeef"
        )
        let file = PluginRegistryFile(version: 1, name: "T", plugins: [entry])
        let cached = CachedRegistry(
            registryURL: URL(string: "https://example.com/registry.json")!,
            registry: file,
            etag: "W/\"abc\"",
            lastModified: "Wed, 21 Oct 2026 07:28:00 GMT",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(cached)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CachedRegistry.self, from: data)
        #expect(decoded == cached)
    }
}
