import Foundation

/// One cover hit returned by a search source (Open Library, Google Books,
/// etc.). Source-agnostic — each provider precomputes thumbnail and full URLs
/// and tags the candidate with a stable, source-prefixed id.
nonisolated struct CoverCandidate: Sendable, Hashable, Identifiable {
    let id: String
    let title: String
    let authors: [String]
    let thumbnailURL: URL
    let fullURL: URL
    let source: CoverSource
}

nonisolated enum CoverSource: String, Sendable, Hashable {
    case iTunes
    case openLibrary
    case googleBooks
}

nonisolated enum CoverFetchError: LocalizedError {
    case badResponse
    case decoding
    case network(URLError)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "The cover source returned an unexpected response."
        case .decoding: return "Couldn't read the cover source's results."
        case .network: return "Couldn't reach the cover source."
        }
    }
}

/// Pure HTTPS GET that returns the bytes at `url`. Shared by all cover
/// sources for image downloads.
nonisolated func fetchCoverBytes(from url: URL) async throws -> Data {
    do {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CoverFetchError.badResponse
        }
        return data
    } catch let urlError as URLError {
        throw CoverFetchError.network(urlError)
    }
}
