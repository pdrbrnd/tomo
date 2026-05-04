import Foundation

nonisolated struct LanguageProfile: Codable, Sendable, Identifiable, Equatable {
    let id: String  // BCP 47 tag, e.g. "pt-PT", "en-GB"
    let baseLanguage: String  // ISO 639-1, e.g. "pt", "en" — used to filter candidates by NLLanguageRecognizer output
    let markers: [Marker]

    /// Localized human-readable name derived from the BCP 47 id via Apple's
    /// `Locale` API. Free localization for whatever UI language is active.
    var displayName: String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }
}

nonisolated struct Marker: Codable, Sendable, Equatable {
    let pattern: String
    let isRegex: Bool
    let weight: Double  // can be negative
}
