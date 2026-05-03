import Foundation

nonisolated struct LanguageProfile: Codable, Sendable, Identifiable, Equatable {
    let id: String              // "pt-PT", "pt-BR", "en-GB", "en-US"
    let label: String           // user-facing, e.g. "Portuguese (Portugal)"
    let baseLanguage: String    // ISO 639-1, e.g. "pt", "en"
    let markers: [Marker]
}

nonisolated struct Marker: Codable, Sendable, Equatable {
    let pattern: String
    let isRegex: Bool
    let weight: Double          // can be negative
}
