import AppKit
import Foundation
import SwiftSoup
import WebKit

/// Standalone WKWebView driver used to validate Cloudflare bypass against
/// Anna's Archive. If this works, the same config ports into the app's
/// `PluginBrowser` for the `fetchBrowser` plugin binding.
@MainActor
final class BrowserDriver: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private let window: NSWindow
    private var loadContinuation: CheckedContinuation<Void, Error>?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()

        // Stealth user script — masks the headless tells Cloudflare looks for.
        // From Will6855/Annas-API's puppeteer-stealth setup, distilled to the
        // pieces that matter for a real WebKit (not Chromium-headless).
        let stealth = """
            Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
            Object.defineProperty(navigator, 'plugins', { get: () => [1,2,3,4,5] });
            Object.defineProperty(navigator, 'languages', { get: () => ['en-US','en'] });
            if (!window.chrome) { window.chrome = { runtime: {} }; }
            """
        config.userContentController.addUserScript(
            WKUserScript(
                source: stealth,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false))

        let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        self.webView = WKWebView(frame: frame, configuration: config)
        self.webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

        // Off-screen window so the WKWebView has a host view but isn't visible.
        // WKWebView needs a non-zero frame and a window to fully initialise its
        // rendering pipeline; an unattached one silently mis-renders.
        self.window = NSWindow(
            contentRect: NSRect(x: -3000, y: -3000, width: 1280, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        self.window.contentView = webView

        super.init()
        webView.navigationDelegate = self
    }

    /// Loads `url`, waits for `didFinish`, then polls `document.title` until it
    /// stops being the Cloudflare challenge page. Returns the rendered HTML.
    func fetch(url: URL, timeout: TimeInterval = 30) async throws -> (html: String, finalURL: URL) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loadContinuation = cont
            webView.load(URLRequest(url: url))
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let title = (try? await webView.evaluateJavaScript("document.title") as? String) ?? ""
            // Known anti-bot challenge pages: Cloudflare ("Just a moment..."),
            // DDoS-Guard ("DDoS-Guard"). Both serve a holding page that swaps
            // out for the real content after their JS check passes.
            let lowered = title.lowercased()
            let isChallenge =
                lowered.contains("just a moment")
                || lowered.contains("ddos-guard")
                || lowered.isEmpty
            if !isChallenge {
                let html =
                    (try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String) ?? ""
                return (html, webView.url ?? url)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw BrowserSpikeError.timeout
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.loadContinuation?.resume()
            self.loadContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        Task { @MainActor in
            self.loadContinuation?.resume(throwing: error)
            self.loadContinuation = nil
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        Task { @MainActor in
            self.loadContinuation?.resume(throwing: error)
            self.loadContinuation = nil
        }
    }
}

enum BrowserSpikeError: Error, CustomStringConvertible {
    case timeout
    var description: String {
        switch self {
        case .timeout: return "browser fetch timed out (Cloudflare challenge unresolved)"
        }
    }
}

@MainActor
func runBrowser(query: String) async {
    // Initialise NSApp so WKWebView's machinery can attach to the run loop.
    _ = NSApplication.shared

    print("→ initialising WKWebView…")
    let driver = BrowserDriver()

    let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
    // Canonical Anna's Archive: .org is NXDOMAIN as of 2026-05; .li is squatted;
    // .io is a different/restricted variant; .gd serves the real content with
    // /md5/ identifiers and slow_download links.
    let url = URL(string: "https://annas-archive.gd/search?q=\(escaped)&ext=epub")!

    print("→ loading \(url)")
    let started = Date()
    do {
        let (html, finalURL) = try await driver.fetch(url: url, timeout: 35)
        let elapsed = Date().timeIntervalSince(started)
        print("← \(html.count) bytes in \(String(format: "%.1f", elapsed))s")
        print("← final URL: \(finalURL)")

        let doc = try SwiftSoup.parse(html)
        let mdAnchors = try doc.select("a[href^=/md5/]")
        let titleLinks = try doc.select("a.font-semibold[href^=/md5/]")
        let rows = try doc.select("div.flex.border-b")
        print("← /md5/ anchors: \(mdAnchors.count) (title links: \(titleLinks.count), rows: \(rows.count))")

        for el in titleLinks.array().prefix(5) {
            let href = (try? el.attr("href")) ?? ""
            let title = (try? el.text()) ?? ""
            print("  - \(href): \(title.prefix(80))")
        }

        // Now exercise the slow_download path — that's the bit that actually
        // needs WKWebView for DDoS-Guard. Pick the first /md5/ result.
        if let firstMD5 = try? doc.select("a[href^=/md5/]").first()?.attr("href"),
            let mdHash = firstMD5.split(separator: "/").last
        {
            print("\n→ probing slow_download for md5 \(mdHash)…")
            let slowURL = URL(string: "https://annas-archive.gd/slow_download/\(mdHash)/0/0")!
            let (slowHTML, slowFinal) = try await driver.fetch(url: slowURL, timeout: 30)
            print("← slow_download: \(slowHTML.count) bytes, final URL: \(slowFinal)")
            // Look for direct file URL or "Download now" anchor on the page.
            let slowDoc = try SwiftSoup.parse(slowHTML)
            let allAnchors = try slowDoc.select("a[href]")
            print("← anchors on slow_download page: \(allAnchors.count)")
            let fileLinks = allAnchors.array().compactMap { try? $0.attr("href") }
                .filter { $0.range(of: "\\.(epub|pdf|mobi|azw3?|djvu)(\\?|$)", options: .regularExpression) != nil }
            print("← direct file URLs: \(fileLinks.count)")
            for f in fileLinks.prefix(3) { print("  - \(f)") }
            // Also surface page title to detect "you must wait X seconds" prompts.
            let slowTitle = try slowDoc.title()
            print("← slow_download page title: \(slowTitle)")
        }

        if mdAnchors.count == 0 {
            // Diagnostic: what does the page look like?
            print("⚠ no /md5/ anchors found")
            let lowered = html.lowercased()
            if lowered.contains("just a moment") || lowered.contains("__cf_chl_") {
                print("  ↳ Cloudflare challenge page still present — challenge didn't resolve")
            } else if lowered.contains("captcha") || lowered.contains("turnstile") {
                print("  ↳ CAPTCHA / Turnstile detected — needs human verification")
            } else {
                // Dump diagnostic info: count hex32s, sample anchors, look for
                // <!-- comment-stripped --> result blocks that Anna's uses to
                // defeat scrapers. The real result rows might be inside
                // HTML comments waiting for client JS to unwrap them.
                let hex32 =
                    (try? NSRegularExpression(pattern: "[a-f0-9]{32}", options: []))
                    .map { $0.numberOfMatches(in: html, range: NSRange(html.startIndex..., in: html)) } ?? 0
                print("  ↳ 32-char hex tokens in HTML: \(hex32)")
                let allAnchors = try doc.select("a[href]")
                print("  ↳ total <a href> count: \(allAnchors.count)")
                let sampled = allAnchors.array().prefix(10).compactMap { try? $0.attr("href") }
                for s in sampled { print("    href: \(s)") }
                // Anna's "comment-stripping" technique: each result row is
                // wrapped in <!-- ... --> and unwrapped client-side. Detect.
                let commentCount = html.components(separatedBy: "<!--").count - 1
                print("  ↳ HTML comments: \(commentCount)")
                let dump = "/tmp/anna-search-dump.html"
                try? html.write(toFile: dump, atomically: true, encoding: .utf8)
                print("  ↳ full HTML written to \(dump)")
            }
            exit(1)
        }
        print("✓ Cloudflare bypass appears to work for Anna's Archive.")
    } catch {
        let elapsed = Date().timeIntervalSince(started)
        fputs("✗ fetch failed after \(String(format: "%.1f", elapsed))s: \(error)\n", stderr)
        exit(1)
    }
}
