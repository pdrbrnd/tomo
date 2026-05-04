import Foundation
import os

/// One cover hit from Open Library's search endpoint, deduped by `coverID`.
nonisolated struct CoverCandidate: Sendable, Hashable, Identifiable {
    let coverID: Int
    let title: String
    let authors: [String]
    let publishYear: Int?

    var id: Int { coverID }
}

nonisolated enum CoverSize: String {
    case small = "S"
    case medium = "M"
    case large = "L"
}

nonisolated enum OpenLibraryError: LocalizedError {
    case badResponse
    case decoding
    case network(URLError)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Open Library returned an unexpected response."
        case .decoding: return "Couldn't read Open Library results."
        case .network: return "Couldn't reach Open Library."
        }
    }
}

/// Pure-Swift Open Library client used by the cover gallery. No auth, no
/// session state. Only invoked from explicit user actions (Principle 5).
nonisolated enum OpenLibraryService {
    /// Search Open Library by title (and optionally author). Returns one
    /// candidate per distinct cover image, capped at 20.
    static func searchCovers(title: String, author: String?) async throws -> [CoverCandidate] {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return [] }

        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "title", value: trimmedTitle),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "fields", value: "key,cover_i,title,author_name,first_publish_year")
        ]
        if let author {
            let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedAuthor.isEmpty {
                items.append(URLQueryItem(name: "author", value: trimmedAuthor))
            }
        }
        components.queryItems = items

        guard let url = components.url else { throw OpenLibraryError.badResponse }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch let urlError as URLError {
            throw OpenLibraryError.network(urlError)
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OpenLibraryError.badResponse
        }

        let decoded: SearchResponse
        do {
            decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        } catch {
            metadataLogger.error("OpenLibrary decode failed: \(error.localizedDescription, privacy: .public)")
            throw OpenLibraryError.decoding
        }

        var seen: Set<Int> = []
        var results: [CoverCandidate] = []
        for doc in decoded.docs {
            guard let coverID = doc.cover_i, !seen.contains(coverID) else { continue }
            seen.insert(coverID)
            results.append(CoverCandidate(
                coverID: coverID,
                title: doc.title ?? trimmedTitle,
                authors: doc.author_name ?? [],
                publishYear: doc.first_publish_year
            ))
        }
        return results
    }

    /// Build the URL for a given cover ID and size. Pure — no I/O.
    static func coverURL(_ id: Int, size: CoverSize) -> URL {
        URL(string: "https://covers.openlibrary.org/b/id/\(id)-\(size.rawValue).jpg")!
    }

    /// Fetch the bytes for a specific cover at the given size.
    static func fetchCoverData(coverID: Int, size: CoverSize) async throws -> Data {
        let url = coverURL(coverID, size: size)
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw OpenLibraryError.badResponse
            }
            return data
        } catch let urlError as URLError {
            throw OpenLibraryError.network(urlError)
        }
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
