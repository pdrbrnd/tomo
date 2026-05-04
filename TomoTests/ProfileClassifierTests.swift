import Foundation
import Testing

@testable import Tomo

@Suite("ProfileClassifier.classify")
struct ProfileClassifierTests {

    @Test func emptyProfilesReturnsNil() {
        #expect(ProfileClassifier.classify(text: "anything", profiles: []) == nil)
    }

    @Test func soleMatchingProfileGetsConfidenceOne() {
        let profile = makeProfile(id: "pt-PT", markers: [.literal("portugal", weight: 1)])
        let result = ProfileClassifier.classify(text: "lisbon portugal porto", profiles: [profile])
        #expect(result?.profileId == "pt-PT")
        #expect(result?.confidence == 1.0)
    }

    @Test func bestScoringProfileWins() {
        let pt = makeProfile(id: "pt-PT", markers: [.literal("portugal", weight: 1)])
        let br = makeProfile(id: "pt-BR", markers: [.literal("brasil", weight: 1)])
        let result = ProfileClassifier.classify(text: "rio brasil sao paulo", profiles: [pt, br])
        #expect(result?.profileId == "pt-BR")
    }

    @Test func confidenceNormalisesAcrossPositiveScores() {
        // pt: 3 hits × 1.0 = 3; br: 1 hit × 1.0 = 1. Confidence for the
        // winner = 3 / (3 + 1) = 0.75.
        let pt = makeProfile(id: "pt-PT", markers: [.literal("portugal", weight: 1)])
        let br = makeProfile(id: "pt-BR", markers: [.literal("brasil", weight: 1)])
        let text = "portugal portugal portugal brasil"
        let result = ProfileClassifier.classify(text: text, profiles: [pt, br])
        #expect(result?.profileId == "pt-PT")
        #expect(abs((result?.confidence ?? 0) - 0.75) < 0.0001)
    }

    @Test func negativeMarkersDemoteScore() {
        // Without the negative marker, "brasil" would score 1 for pt-PT.
        // With it, the score is 1 + (-2) = -1, which falls below zero and
        // is dropped — pt-BR wins on its raw 1.
        let pt = makeProfile(
            id: "pt-PT",
            markers: [
                .literal("portugal", weight: 1),
                .literal("brasil", weight: -2),
            ])
        let br = makeProfile(id: "pt-BR", markers: [.literal("brasil", weight: 1)])
        let result = ProfileClassifier.classify(text: "rio brasil", profiles: [pt, br])
        #expect(result?.profileId == "pt-BR")
    }

    @Test func allNonPositiveScoresReturnNil() {
        let pt = makeProfile(id: "pt-PT", markers: [.literal("missing-token", weight: 1)])
        let result = ProfileClassifier.classify(text: "nothing relevant here", profiles: [pt])
        #expect(result == nil)
    }

    @Test func regexMarkersMatchEachOccurrence() {
        // Regex \bportugal\b matches each whole-word occurrence; score = 3 × 2 = 6.
        let pt = makeProfile(id: "pt-PT", markers: [.regex(#"\bportugal\b"#, weight: 2)])
        let result = ProfileClassifier.classify(
            text: "portugal portugal portugal portugalia",  // last is partial → no match
            profiles: [pt]
        )
        #expect(result?.profileId == "pt-PT")
    }

    @Test func literalMatchingIsCaseInsensitive() {
        // `classify` lowercases the input before scoring, so literal markers
        // need to be lowercase but text can be any case.
        let pt = makeProfile(id: "pt-PT", markers: [.literal("portugal", weight: 1)])
        let result = ProfileClassifier.classify(text: "Portugal PORTUGAL", profiles: [pt])
        #expect(result?.profileId == "pt-PT")
    }
}

private extension Marker {
    static func literal(_ pattern: String, weight: Double) -> Marker {
        Marker(pattern: pattern, isRegex: false, weight: weight)
    }

    static func regex(_ pattern: String, weight: Double) -> Marker {
        Marker(pattern: pattern, isRegex: true, weight: weight)
    }
}

private func makeProfile(id: String, markers: [Marker]) -> LanguageProfile {
    LanguageProfile(id: id, baseLanguage: String(id.prefix(2)), markers: markers)
}
