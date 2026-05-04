import Foundation

nonisolated struct Classification: Sendable, Equatable {
    let profileId: String
    let confidence: Double  // 0...1, normalized over candidate scores
}

nonisolated enum ProfileClassifier {
    /// Scores `text` against each profile and returns the best match. Returns
    /// nil if no profile produces a positive score (no markers matched).
    /// Caller is responsible for filtering profiles to a single base language.
    static func classify(text: String, profiles: [LanguageProfile]) -> Classification? {
        guard !profiles.isEmpty else { return nil }
        let normalized = text.lowercased()

        let scores = profiles.map { profile in
            (id: profile.id, score: score(text: normalized, profile: profile))
        }

        guard let best = scores.max(by: { $0.score < $1.score }), best.score > 0 else {
            return nil
        }

        // Clamp scores at 0 for normalization so negative markers can't push
        // confidence above 1.0 or distort the ratio.
        let positiveTotal = scores.map { max($0.score, 0) }.reduce(0, +)
        let confidence = positiveTotal > 0 ? best.score / positiveTotal : 0
        return Classification(profileId: best.id, confidence: confidence)
    }

    private static func score(text: String, profile: LanguageProfile) -> Double {
        var total: Double = 0
        for marker in profile.markers {
            let count = matchCount(text: text, pattern: marker.pattern, isRegex: marker.isRegex)
            total += Double(count) * marker.weight
        }
        return total
    }

    private static func matchCount(text: String, pattern: String, isRegex: Bool) -> Int {
        if isRegex {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return 0
            }
            let range = NSRange(text.startIndex..., in: text)
            return regex.numberOfMatches(in: text, options: [], range: range)
        }
        let needle = pattern.lowercased()
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = text.startIndex..<text.endIndex
        while let found = text.range(of: needle, range: range) {
            count += 1
            range = found.upperBound..<text.endIndex
        }
        return count
    }
}
