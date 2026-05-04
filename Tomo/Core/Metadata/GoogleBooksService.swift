import Foundation
import ImageIO
import os

/// Pure-Swift Google Books client. No auth required for read-only volume
/// search at low volume (well within the 1000 queries/day/IP free tier).
/// Only invoked from explicit user actions (Principle 5).
///
/// Used as the *last-resort* source — Google's catalogue is broad but its
/// "image not available" placeholder is served at the same URL pattern as
/// real covers, so we filter results post-search by decoding image dimensions
/// (the placeholder is a fixed 128×192; real covers at `zoom=2` are
/// 600×900-ish).
nonisolated enum GoogleBooksService {
    /// Minimum short-edge size in pixels. Google's "image not available"
    /// graphic is 128×192 regardless of `zoom` parameter; real publisher
    /// art is reliably ≥300px on the short edge. 200 leaves headroom while
    /// rejecting all known placeholder variants.
    private static let minimumShortEdge = 200

    /// Search Google Books by title (and optionally author). Returns one
    /// candidate per volume that has a *real* cover image — placeholders
    /// are filtered out by decoding dimensions.
    static func searchCovers(title: String, author: String?) async throws -> [CoverCandidate] {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return [] }

        // Quoted phrases bias Google's ranker toward exact title/author
        // matches and cut down on the same-author-but-different-book
        // pollution that plagues short titles like "The Stranger".
        var query = "intitle:\"\(trimmedTitle)\""
        if let author {
            let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedAuthor.isEmpty {
                query += " inauthor:\"\(trimmedAuthor)\""
            }
        }

        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: "40"),
            URLQueryItem(name: "printType", value: "books"),
            URLQueryItem(name: "fields", value: "items(id,volumeInfo(title,authors,imageLinks))")
        ]

        guard let url = components.url else { throw CoverFetchError.badResponse }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch let urlError as URLError {
            throw CoverFetchError.network(urlError)
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CoverFetchError.badResponse
        }

        let decoded: SearchResponse
        do {
            decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        } catch {
            metadataLogger.error("GoogleBooks decode failed: \(error.localizedDescription, privacy: .public)")
            throw CoverFetchError.decoding
        }

        var seen: Set<String> = []
        var rawResults: [CoverCandidate] = []
        for item in decoded.items ?? [] {
            guard let info = item.volumeInfo,
                  let links = info.imageLinks,
                  let raw = links.thumbnail ?? links.smallThumbnail else { continue }
            // Some legacy responses still return http://; Google serves https on
            // the same path so a literal swap is safe and avoids ATS blocks.
            let httpsRaw = raw.replacingOccurrences(of: "http://", with: "https://")
            guard let thumbURL = URL(string: httpsRaw),
                  !seen.contains(item.id) else { continue }
            seen.insert(item.id)
            let upgraded = upgradeForFullSize(thumbURL)
            rawResults.append(CoverCandidate(
                id: "gb-\(item.id)",
                title: info.title ?? trimmedTitle,
                authors: info.authors ?? [],
                thumbnailURL: upgraded,
                fullURL: upgraded,
                source: .googleBooks
            ))
        }

        return await filterRealCovers(rawResults)
    }

    /// Probes each candidate's thumbnail in parallel and keeps only the
    /// ones whose decoded short edge ≥ `minimumShortEdge`. The bytes are
    /// cached by `URLCache.shared`, so `AsyncImage`'s subsequent fetch in
    /// the gallery grid is free.
    private static func filterRealCovers(_ candidates: [CoverCandidate]) async -> [CoverCandidate] {
        await withTaskGroup(of: (Int, CoverCandidate?).self) { group in
            for (index, candidate) in candidates.enumerated() {
                group.addTask {
                    let kept = await isLikelyRealCover(url: candidate.thumbnailURL) ? candidate : nil
                    return (index, kept)
                }
            }
            // Preserve the original ranking order — Google's relevance sort
            // is more useful than insertion order from a TaskGroup.
            var keptByIndex: [Int: CoverCandidate] = [:]
            for await (index, kept) in group {
                if let kept { keptByIndex[index] = kept }
            }
            return candidates.indices.compactMap { keptByIndex[$0] }
        }
    }

    private static func isLikelyRealCover(url: URL) async -> Bool {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return false
            }
            guard let dimensions = imageDimensions(from: data) else { return false }
            return min(dimensions.width, dimensions.height) >= minimumShortEdge
        } catch {
            return false
        }
    }

    /// Read width/height from image header bytes via ImageIO without fully
    /// decoding pixels — fast (microseconds) for any common format.
    private static func imageDimensions(from data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            return nil
        }
        return (width, height)
    }

    /// Google Books cover URLs carry a `zoom` parameter and an `&edge=curl`
    /// page-curl effect on thumbnails. Strip the curl and rewrite the zoom
    /// value via `URLComponents` so we only ever touch the actual `zoom`
    /// query item (a string `replacingOccurrences` on `zoom=N` could match
    /// substrings like `zoom=10` if they ever ship one).
    ///
    /// `zoom=2` is the sweet spot for our use: it returns ~600×900 covers
    /// (sharp on retina cells) without the strange oversized renderings
    /// `zoom=3` sometimes serves for books whose hi-res variant is a page
    /// preview rather than just the cover art.
    private static func upgradeForFullSize(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = (components.queryItems ?? []).filter { $0.name != "edge" }
        if let i = items.firstIndex(where: { $0.name == "zoom" }) {
            items[i].value = "2"
        } else {
            items.append(URLQueryItem(name: "zoom", value: "2"))
        }
        components.queryItems = items
        return components.url ?? url
    }

    private struct SearchResponse: Decodable, Sendable {
        let items: [Volume]?
    }

    private struct Volume: Decodable, Sendable {
        let id: String
        let volumeInfo: VolumeInfo?
    }

    private struct VolumeInfo: Decodable, Sendable {
        let title: String?
        let authors: [String]?
        let imageLinks: ImageLinks?
    }

    private struct ImageLinks: Decodable, Sendable {
        let smallThumbnail: String?
        let thumbnail: String?
    }
}
