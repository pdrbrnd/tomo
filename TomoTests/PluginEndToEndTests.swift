import Foundation
import Testing

@testable import Tomo

/// Live end-to-end check of source plugins against their real upstreams:
/// load the `.js` through the production `PluginSource` → run `search()` with a
/// canned query → run `download()` on the first hit → fetch the first bytes of
/// the returned URL and check they're an EPUB (zip) or PDF.
///
/// Hits third-party servers, so it's **opt-in** and never part of the normal
/// `xcodebuild test` run:
///
///     TEST_RUNNER_TOMO_PLUGIN_E2E=1 \
///     TEST_RUNNER_TOMO_PLUGIN_E2E_DIR="$HOME/code/tomo-plugins/plugins:$HOME/Library/Application Support/com.pdrbrnd.tomo/plugins" \
///     xcodebuild test -project Tomo.xcodeproj -scheme Tomo -destination 'platform=macOS' \
///       -only-testing:TomoTests/PluginEndToEndTests
///
/// (`xcodebuild` forwards `TEST_RUNNER_*` variables to the test process with
/// the prefix stripped.) `TOMO_PLUGIN_E2E_DIR` is a colon-separated list of
/// directories; it defaults to the app's installed plugins folder.
/// `TOMO_PLUGIN_E2E_QUERY` overrides the search text for every plugin.
///
/// Runs serialized: plugins share `HTTPCookieStorage.shared` and the challenge
/// solver's webview, and parallel scraping of the same host gets rate-limited.
@Suite("Plugins end-to-end", .enabled(if: PluginEndToEnd.isEnabled), .serialized)
@MainActor
struct PluginEndToEndTests {

    @Test(arguments: PluginEndToEnd.pluginFiles())
    func searchAndDownload(pluginFile: URL) async throws {
        let fallbackID = pluginFile.deletingPathExtension().lastPathComponent
        let source = try String(contentsOf: pluginFile, encoding: .utf8)
        let plugin = try PluginSource(fallbackID: fallbackID, source: source)
        let text = PluginEndToEnd.queryText(for: plugin.id)
        let query = PluginQuery(
            text: text, title: nil, author: nil, language: nil,
            isbn: nil, format: nil, year: nil, publisher: nil)

        let clock = ContinuousClock()
        var start = clock.now
        let results = try await plugin.search(query)
        let searchDuration = clock.now - start

        let withCover = results.filter { $0.coverURL != nil }.count
        print(
            "[e2e] \(plugin.id): search \"\(text)\" → \(results.count) results, \(withCover) with cover, \(searchDuration)"
        )
        for r in results.prefix(3) {
            print("[e2e]   - \(r.title) — \(r.authors.joined(separator: ", ")) [\(r.format), \(r.language)]")
        }

        #expect(!results.isEmpty, "\(plugin.id): search for \"\(text)\" returned nothing")
        for r in results {
            #expect(
                !r.title.trimmingCharacters(in: .whitespaces).isEmpty, "\(plugin.id): result \(r.id) has empty title")
            #expect(
                r.format == "epub" || r.format == "pdf",
                "\(plugin.id): result \(r.id) has non-importable format \(r.format)")
        }
        guard let first = results.first else { return }

        start = clock.now
        let outcome = try await plugin.download(first)
        let downloadDuration = clock.now - start

        switch outcome {
        case .browser(let url):
            // Needs a human to click through; the contract allows it, and
            // there's nothing further we can verify unattended.
            print("[e2e] \(plugin.id): download → browser \(url) (\(downloadDuration))")
        case .url(let url):
            print("[e2e] \(plugin.id): download → \(url) (\(downloadDuration))")
            start = clock.now
            let (magic, response) = try await PluginEndToEnd.fetchMagicBytes(url)
            print(
                "[e2e] \(plugin.id): HTTP \(response.statusCode) \(response.value(forHTTPHeaderField: "Content-Type") ?? "?") \(response.value(forHTTPHeaderField: "Content-Length") ?? "?") bytes, \(clock.now - start)"
            )
            #expect(response.statusCode == 200, "\(plugin.id): download URL answered HTTP \(response.statusCode)")
            let kind = PluginEndToEnd.fileKind(magic)
            #expect(
                kind != nil,
                "\(plugin.id): download body doesn't start like an EPUB or PDF (first bytes: \(magic.map { String(format: "%02x", $0) }.joined()))"
            )
            if let kind {
                #expect(kind == first.format, "\(plugin.id): result says \(first.format) but the file is a \(kind)")
            }
        }
    }
}

nonisolated enum PluginEndToEnd {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["TOMO_PLUGIN_E2E"] == "1"
    }

    /// Every `.js` under the configured directories, alphabetical per dir.
    static func pluginFiles() -> [URL] {
        guard isEnabled else { return [] }
        let env = ProcessInfo.processInfo.environment
        let dirs: [URL]
        if let raw = env["TOMO_PLUGIN_E2E_DIR"], !raw.isEmpty {
            dirs = raw.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        } else {
            dirs = PluginDirectory.directoryURL().map { [$0] } ?? []
        }
        return dirs.flatMap { dir -> [URL] in
            let contents =
                (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return
                contents
                .filter { $0.pathExtension.lowercased() == "js" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    /// A query each source is known to have hits for. Public-domain
    /// catalogues won't have Herbert; shadow libraries will.
    static func queryText(for pluginID: String) -> String {
        if let override = ProcessInfo.processInfo.environment["TOMO_PLUGIN_E2E_QUERY"], !override.isEmpty {
            return override
        }
        switch pluginID {
        case "libgen", "annas": return "dune herbert"
        default: return "frankenstein"
        }
    }

    /// Streams just enough of the body to sniff the file type, then stops.
    /// Same UA as the plugin bindings so anti-bot cookies earned during
    /// search still apply.
    static func fetchMagicBytes(_ url: URL) async throws -> ([UInt8], HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(PluginHost.browserUserAgent, forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PluginError.runtime("non-HTTP response from \(url)")
        }
        var magic: [UInt8] = []
        for try await byte in bytes {
            magic.append(byte)
            if magic.count == 4 { break }
        }
        bytes.task.cancel()
        return (magic, http)
    }

    static func fileKind(_ magic: [UInt8]) -> String? {
        if magic.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "epub" }
        if magic.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "pdf" }
        return nil
    }
}
