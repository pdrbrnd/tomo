import Foundation
import os

/// Apple iTunes Search API client. Free, no auth, ~20 req/min unauthenticated.
///
/// Why iTunes is our primary source: artwork is publisher-supplied at very
/// high resolution, and there's no "image not available" placeholder problem
/// — if a book isn't in the Apple Books catalogue, the API returns no result
/// rather than a stub cover. Coverage skews mainstream English + the local
/// store's catalogue (PT for Portugal); Apple stores don't fully overlap, so
/// we query US + PT in parallel and merge.
nonisolated enum AppleBooks {
    /// Search the US + PT Apple Books stores in parallel and return merged,
    /// deduped candidates. Per-store failures don't poison the other.
    static func searchCovers(title: String, author: String?) async throws -> [CoverCandidate] {
        async let us = trySearch(title: title, author: author, country: "US")
        async let pt = trySearch(title: title, author: author, country: "PT")
        let (usHits, ptHits) = await (us, pt)
        if usHits == nil && ptHits == nil {
            // Both stores erred — surface as a CoverFetchError so the sheet
            // can decide whether to display the error or fall back silently.
            throw CoverFetchError.badResponse
        }
        return mergeUnique((usHits ?? []) + (ptHits ?? []))
    }

    private static func trySearch(title: String, author: String?, country: String) async -> [CoverCandidate]? {
        do {
            return try await searchOne(title: title, author: author, country: country)
        } catch {
            metadataLogger.error(
                "iTunes \(country, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func searchOne(title: String, author: String?, country: String) async throws -> [CoverCandidate] {
        let term = [title, author]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !term.isEmpty else { return [] }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "ebook"),
            URLQueryItem(name: "entity", value: "ebook"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: "20"),
        ]
        guard let url = components.url else { throw CoverFetchError.badResponse }

        let decoded = try await fetchJSON(SearchResponse.self, from: url, sourceName: "AppleBooks-\(country)")

        return decoded.results.compactMap { result in
            guard let artwork100 = result.artworkUrl100,
                let hiRes = upscaleArtwork(artwork100)
            else { return nil }
            return CoverCandidate(
                id: "itunes-\(country.lowercased())-\(result.trackId)",
                title: result.trackName ?? title,
                authors: result.artistName.map { [$0] } ?? [],
                thumbnailURL: hiRes,
                fullURL: hiRes,
                source: .appleBooks
            )
        }
    }

    /// Apple serves ebook artwork as 100×100 thumbnails by default. The
    /// `100000x100000-999.jpg` trick that works for music/podcast assets
    /// returns HTTP 400 on `Publication*` ebook URLs — those are served by
    /// a different asset pipeline that only honours a narrower set of size
    /// tokens. `1200x1200bb.jpg` is the universal sweet spot: always
    /// available, ~400KB, sharp on retina cells.
    ///
    /// Real-world ebook URLs end with one of:
    ///   /100x100bb.jpg
    ///   /100x100bb-85.jpg     (older quality suffix)
    ///   /100x100.png          (no `bb`)
    /// Regex-substituting the trailing size token covers all of them in one
    /// shot.
    /// Pattern is a constant — compile failure would be a programming error,
    /// so we force-unwrap once at load time rather than `try?` per call.
    private static let upscaleRegex: NSRegularExpression = {
        let pattern = #"/\d+x\d+(?:bb|cc)?(?:-\d+)?\.(?:jpg|jpeg|png)$"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static func upscaleArtwork(_ artworkURL: String) -> URL? {
        let nsRange = NSRange(artworkURL.startIndex..<artworkURL.endIndex, in: artworkURL)
        let upscaled = upscaleRegex.stringByReplacingMatches(
            in: artworkURL,
            options: [],
            range: nsRange,
            withTemplate: "/1200x1200bb.jpg"
        )
        return URL(string: upscaled)
    }

    /// Dedup by trackId across stores. The same book usually carries the same
    /// numeric `trackId` in both US and PT, so this collapses cross-store
    /// duplicates while keeping store-exclusive results.
    private static func mergeUnique(_ candidates: [CoverCandidate]) -> [CoverCandidate] {
        var seenTrackIDs: Set<String> = []
        var out: [CoverCandidate] = []
        for candidate in candidates {
            // The id is `itunes-{country}-{trackId}` — strip country to dedup.
            let trackKey = candidate.id
                .replacingOccurrences(of: "itunes-us-", with: "")
                .replacingOccurrences(of: "itunes-pt-", with: "")
            guard !seenTrackIDs.contains(trackKey) else { continue }
            seenTrackIDs.insert(trackKey)
            out.append(candidate)
        }
        return out
    }

    private struct SearchResponse: Decodable, Sendable {
        let results: [Result]
    }

    private struct Result: Decodable, Sendable {
        let trackId: Int
        let trackName: String?
        let artistName: String?
        let artworkUrl100: String?
    }
}
