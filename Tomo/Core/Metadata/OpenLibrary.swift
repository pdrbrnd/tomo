import Foundation
import os

/// Pure-Swift Open Library client. No auth, no session state. Only invoked
/// from explicit user actions (Principle 5).
nonisolated enum OpenLibrary {
    /// Search Open Library by title (and optionally author). Returns one
    /// candidate per distinct cover image, capped at 20.
    static func searchCovers(title: String, author: String?) async throws -> [CoverCandidate] {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return [] }

        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "title", value: trimmedTitle),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "fields", value: "key,cover_i,title,author_name,first_publish_year"),
        ]
        if let author {
            let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedAuthor.isEmpty {
                items.append(URLQueryItem(name: "author", value: trimmedAuthor))
            }
        }
        components.queryItems = items

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
            metadataLogger.error("OpenLibrary decode failed: \(error.localizedDescription, privacy: .public)")
            throw CoverFetchError.decoding
        }

        var seen: Set<Int> = []
        var results: [CoverCandidate] = []
        for doc in decoded.docs {
            guard let coverID = doc.cover_i, !seen.contains(coverID) else { continue }
            seen.insert(coverID)
            // Use the large size for thumbnails too — the medium variant is
            // ~180×270, which pixellates badly when scaled to retina cell
            // pixels. URLCache dedupes the commit-time fetch.
            //
            // `?default=false` makes Open Library return HTTP 404 when the
            // cover file is genuinely missing instead of serving their
            // grey "image not available" placeholder JPG. AsyncImage's
            // .failure case then renders our own placeholder.
            let large = URL(string: "https://covers.openlibrary.org/b/id/\(coverID)-L.jpg?default=false")!
            results.append(
                CoverCandidate(
                    id: "ol-\(coverID)",
                    title: doc.title ?? trimmedTitle,
                    authors: doc.author_name ?? [],
                    thumbnailURL: large,
                    fullURL: large,
                    source: .openLibrary
                ))
        }
        return results
    }

    private struct SearchResponse: Decodable, Sendable {
        let docs: [Doc]
    }

    private struct Doc: Decodable, Sendable {
        let key: String?
        let cover_i: Int?
        let title: String?
        let author_name: [String]?
        let first_publish_year: Int?
    }
}
