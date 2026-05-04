import Foundation
import NaturalLanguage

nonisolated enum BaseLanguage {
    /// Detects the dominant base language in the given text using
    /// `NLLanguageRecognizer`. Returns ISO 639-1 code (e.g. "en", "pt") or
    /// nil if the text is too short or the language can't be determined.
    /// Per CLAUDE.md: only used for *base* language detection — variant
    /// detection is the marker classifier's job.
    static func detect(in text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return nil }
        return language.rawValue
    }
}
