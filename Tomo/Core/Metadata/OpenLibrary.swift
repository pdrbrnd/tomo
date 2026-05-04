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

        let decoded = try await fetchJSON(SearchResponse.self, from: url, sourceName: "OpenLibrary")

        var seen: Set<Int> = []
        var results: [CoverCandidate] = []
        for doc in decoded.docs {
            guard let coverID = doc.coverID, !seen.contains(coverID) else { continue }
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
                    authors: doc.authorName ?? [],
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
        let coverID: Int?
        let title: String?
        let authorName: [String]?
        let firstPublishYear: Int?

        enum CodingKeys: String, CodingKey {
            case key
            case coverID = "cover_i"
            case title
            case authorName = "author_name"
            case firstPublishYear = "first_publish_year"
        }
    }
}
