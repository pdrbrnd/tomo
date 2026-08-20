import Foundation
import WebKit
import os

/// Clears the "checking your browser" interstitials some sources put in front
/// of their HTML, so plugin `fetch()` can stay a plain HTTP call.
///
/// **Why this exists.** A plugin scrapes HTML. When a source turns on an
/// anti-bot interstitial, every `fetch()` comes back 403 with a challenge page
/// instead of content and the plugin sees nothing — there's no fix available
/// to it in JS, because the challenge is deliberately un-scriptable.
///
/// **How it works.** The challenge is a JS proof-of-work whose only durable
/// output is a set of cookies. Plugin fetches run through `URLSession.shared`,
/// which reads `HTTPCookieStorage.shared`. So: load the blocked URL in an
/// off-screen `WKWebView` — a real browser engine, so the challenge runs and
/// clears itself with no user interaction — copy the cookies it earned into
/// the shared store, and let the caller retry. Later fetches are plain, fast
/// HTTP again until those cookies expire.
///
/// **Cost.** A solve takes ~15s, because the challenge inserts its own delay.
/// The first search against a gated source pays it; the rest don't.
///
/// **Scope.** Only clears challenges that pass on their own. Interstitials
/// needing a real click (or a CAPTCHA) time out and fail — those need the
/// user-driven `{ kind: "browser" }` download path instead.
///
/// Verified against DDoS-Guard (annas-archive.gl) on 2026-08-20.
@MainActor
enum PluginChallengeSolver {
    private static let logger = Logger(subsystem: "com.pdrbrnd.tomo", category: "plugin-challenge")

    /// How long to let a challenge run before giving up. Observed solve time
    /// is ~15s; the ceiling is loose because the fallback is "source doesn't
    /// work at all".
    private static let timeout: Duration = .seconds(45)

    /// After a failed solve, don't retry this host for a while — a source
    /// that's hard-blocking us shouldn't add 45s to every later fetch.
    private static let failureCooldown: TimeInterval = 120

    /// Below this, a document is still loading rather than being real content.
    /// Guards against harvesting cookies off a half-built page whose markers
    /// simply haven't rendered yet.
    private static let minimumRealPageBytes = 4096

    /// One solve per host at a time. A single search fires several fetches,
    /// which would otherwise each spin up a webview for the same challenge.
    private static var inFlight: [String: Task<Bool, Never>] = [:]
    private static var lastFailure: [String: Date] = [:]

    /// Holds the webview alive for the duration of a solve — nothing else
    /// references it, and a deallocated webview stops running the challenge.
    private static var activeWebView: WKWebView?

    /// Fingerprints of the interstitial vendors we know how to wait out.
    /// Matched against the document *head* only: DDoS-Guard also injects
    /// references to itself into the real page it's protecting, so a
    /// whole-document match would never see a challenge as cleared.
    nonisolated private static let challengeMarkers = [
        "ddos-guard",  // DDoS-Guard's js-challenge and block pages
        "cf-browser-verification",  // Cloudflare, legacy
        "challenge-platform",  // Cloudflare, current
    ]

    /// True when a response is an anti-bot interstitial rather than the page
    /// the plugin asked for. Deliberately narrow: a 2xx never qualifies, so a
    /// real page that happens to mention a vendor is never mistaken for one.
    nonisolated static func isChallengeResponse(status: Int, body: String) -> Bool {
        guard status == 403 || status == 503 else { return false }
        return hasChallengeMarker(body)
    }

    nonisolated private static func hasChallengeMarker(_ html: String) -> Bool {
        let head = html.prefix(4096).lowercased()
        return challengeMarkers.contains { head.contains($0) }
    }

    /// Runs `url`'s challenge to completion in a webview and copies the
    /// resulting cookies into the store plugin fetches read from. Returns
    /// whether the caller should retry its request.
    static func passChallenge(for url: URL) async -> Bool {
        guard let host = url.host else { return false }

        if let failedAt = lastFailure[host], Date().timeIntervalSince(failedAt) < failureCooldown {
            return false
        }
        // Join an in-progress solve for the same host rather than starting a
        // second one.
        if let existing = inFlight[host] { return await existing.value }

        let task = Task<Bool, Never> { await solve(url: url, host: host) }
        inFlight[host] = task
        let solved = await task.value
        inFlight[host] = nil
        lastFailure[host] = solved ? nil : Date()
        return solved
    }

    private static func solve(url: URL, host: String) async -> Bool {
        logger.info("clearing challenge for \(host, privacy: .public)")
        let started = ContinuousClock.now

        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900))
        // Must match what the fetch bindings send: these cookies are issued
        // against the UA that earned them, so the two can't drift.
        web.customUserAgent = PluginHost.browserUserAgent
        activeWebView = web
        defer { activeWebView = nil }

        web.load(URLRequest(url: url))

        while started.duration(to: .now) < timeout {
            try? await Task.sleep(for: .seconds(1))
            guard let page = await probe(web) else { continue }
            guard page.ready == "complete",
                page.length >= minimumRealPageBytes,
                !hasChallengeMarker(page.head)
            else { continue }

            await copyCookies(from: web, host: host)
            let seconds = started.duration(to: .now).components.seconds
            logger.info("challenge cleared for \(host, privacy: .public) in \(seconds)s")
            return true
        }

        logger.warning("challenge not cleared for \(host, privacy: .public) — timed out")
        return false
    }

    private struct PageProbe: Decodable {
        let ready: String
        let length: Int
        let head: String
    }

    /// Reads load state, document size, and the head of the document in one
    /// round-trip. `outerHTML` on a real page is hundreds of KB, so it's
    /// built once in JS and only the leading slice comes back.
    private static func probe(_ web: WKWebView) async -> PageProbe? {
        let js = """
            (() => {
              const html = document.documentElement.outerHTML;
              return JSON.stringify({
                ready: document.readyState,
                length: html.length,
                head: html.slice(0, 4096),
              });
            })()
            """
        guard let raw = (try? await web.evaluateJavaScript(js)) as? String,
            let data = raw.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(PageProbe.self, from: data)
    }

    /// Copies the challenge cookies into the store `URLSession.shared` reads.
    /// Scoped to the host we solved for — the webview's store is shared with
    /// the user-driven browser-download flow, and those cookies have no
    /// business riding along on unrelated plugin fetches.
    private static func copyCookies(from web: WKWebView, host: String) async {
        let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
        var copied = 0
        for cookie in cookies where domainCovers(cookie.domain, host: host) {
            HTTPCookieStorage.shared.setCookie(cookie)
            copied += 1
        }
        logger.info("copied \(copied) cookies for \(host, privacy: .public)")
    }

    /// Cookie-domain match: `.example.com` covers `example.com` and any
    /// subdomain of it.
    private static func domainCovers(_ cookieDomain: String, host: String) -> Bool {
        let bare = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain
        return host == bare || host.hasSuffix("." + bare)
    }
}
