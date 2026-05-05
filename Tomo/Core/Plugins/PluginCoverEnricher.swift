import Foundation

/// Looks up covers for source results that didn't ship one. Reuses the same
/// iTunes (US + PT) + Open Library stack the Cover Gallery sheet uses for
/// library books — single source of truth for cover provenance, and PT's
/// iTunes store gives us the Portuguese-language coverage the plain
/// Open-Library lookup misses.
///
/// Plugin authors aren't responsible for sourcing covers; if they have one
/// (e.g. straight from the source's HTML) it sticks. If not, this enricher
/// fills the gap. The cover lookup network calls here are scoped to the
/// search action the user just initiated — same model as the Cover Gallery
/// sheet, just chained after a plugin search instead of a button click.
nonisolated enum PluginCoverEnricher {

    /// Concurrently looks up a cover for every result whose `coverURL` is
    /// nil. Returns a map of `result.id → URL`. Failures and missing-cover
    /// cases are silently absent from the map.
    static func enrich(_ results: [PluginResult]) async -> [String: URL] {
        await withTaskGroup(of: (String, URL?).self) { group in
            for result in results where result.coverURL == nil {
                group.addTask {
                    let url = await firstCover(
                        title: result.title,
                        author: result.authors.first)
                    return (result.id, url)
                }
            }
            var out: [String: URL] = [:]
            for await (id, url) in group {
                if let url { out[id] = url }
            }
            return out
        }
    }

    /// iTunes US + PT first (publisher-supplied high-res, good multi-store
    /// coverage), then Open Library as fallback.
    ///
    /// Both sources are full-text search engines — they happily return books
    /// by the same author when there's no exact title match (e.g. searching
    /// "As palavras de Saramago" surfaces "O Evangelho Segundo Jesus Cristo"
    /// because both are by Saramago). For an auto-picked cover that's wrong;
    /// `bestMatch` filters candidates to ones whose title (and author, when
    /// known) actually overlap with the query. No match → nil → typography
    /// fallback. Better to show no cover than the wrong one.
    private static func firstCover(title: String, author: String?) async -> URL? {
        if let candidates = try? await AppleBooks.searchCovers(title: title, author: author),
            let pick = bestMatch(candidates, queryTitle: title, queryAuthor: author)
        {
            return pick
        }
        if let candidates = try? await OpenLibrary.searchCovers(title: title, author: author),
            let pick = bestMatch(candidates, queryTitle: title, queryAuthor: author)
        {
            return pick
        }
        return nil
    }

    /// Walks `candidates` in order, returning the first whose title is
    /// similar enough to `queryTitle` and whose authors include `queryAuthor`
    /// when it's set.
    private static func bestMatch(
        _ candidates: [CoverCandidate],
        queryTitle: String,
        queryAuthor: String?
    ) -> URL? {
        let normTitle = normalize(queryTitle)
        let normAuthor = queryAuthor.flatMap { author -> String? in
            let n = normalize(author)
            return n.isEmpty ? nil : n
        }
        for candidate in candidates {
            guard titleMatches(query: normTitle, candidate: normalize(candidate.title)) else { continue }
            if let normAuthor {
                let candAuthors = candidate.authors.map(normalize)
                let anyAuthorMatch = candAuthors.contains { c in
                    !c.isEmpty && (c.contains(normAuthor) || normAuthor.contains(c))
                }
                guard anyAuthorMatch else { continue }
            }
            return candidate.fullURL
        }
        return nil
    }

    /// Title similarity via Jaccard on word sets after normalisation.
    /// 0.5 threshold — 50% of unique non-stopword tokens must overlap. Tuned
    /// against Saramago / Lobo Antunes / Pessoa edge cases:
    ///   "as palavras de saramago" ↔ "o evangelho segundo jesus cristo" → 0.0  (reject)
    ///   "blindness" ↔ "blindness" → 1.0  (accept)
    ///   "the last interview" ↔ "saramago: the last interview" → 0.67  (accept)
    private static func titleMatches(query: String, candidate: String) -> Bool {
        if query == candidate { return true }
        let qTokens = Set(query.split(separator: " ").map(String.init))
        let cTokens = Set(candidate.split(separator: " ").map(String.init))
        guard !qTokens.isEmpty, !cTokens.isEmpty else { return false }
        let intersection = qTokens.intersection(cTokens).count
        let union = qTokens.union(cTokens).count
        return Double(intersection) / Double(union) >= 0.5
    }

    /// Lowercase, drop punctuation, strip leading articles + common
    /// stopwords across EN / PT / ES / FR / IT / DE so titles like
    /// "The Cave" and "A Caverna" still compare on their content words.
    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "of", "to", "in", "on",
        "o", "os", "as", "um", "uns", "umas", "de", "do", "da", "dos", "das", "e",
        "el", "los", "las", "un", "una", "y",
        "le", "les", "un", "une", "des", "et",
        "il", "lo", "gli", "uno", "una", "di",
        "der", "die", "das", "ein", "eine", "und",
    ]

    private static func normalize(_ s: String) -> String {
        let lowered = s.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        var stripped = ""
        stripped.reserveCapacity(lowered.count)
        for scalar in lowered.unicodeScalars {
            if scalar.properties.isAlphabetic || ("0"..."9").contains(Character(scalar)) || scalar == " " {
                stripped.unicodeScalars.append(scalar)
            } else {
                stripped.unicodeScalars.append(" ")
            }
        }
        return
            stripped
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !stopwords.contains($0) }
            .joined(separator: " ")
    }
}
