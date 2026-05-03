import Foundation
import os

nonisolated enum Classifier {
    /// Runs the full pipeline on an EPUB: extract text → detect base language
    /// → score against profiles for that base. Returns nil when text can't be
    /// extracted, base language can't be detected, no profiles match the base,
    /// or no markers fire. Logs each failure path.
    static func classifyEPUB(at url: URL, profiles: [LanguageProfile]) -> Classification? {
        let text: String
        do {
            text = try EPUBText.extract(from: url)
        } catch {
            classifierLogger.error("text extract failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard !text.isEmpty else {
            classifierLogger.info("empty extracted text — skipping classification")
            return nil
        }
        guard let baseLang = BaseLanguage.detect(in: text) else {
            classifierLogger.info("could not detect base language")
            return nil
        }
        let candidates = profiles.filter { $0.baseLanguage == baseLang }
        guard !candidates.isEmpty else {
            classifierLogger.info("no profiles for base language \(baseLang, privacy: .public)")
            return nil
        }
        guard let result = ProfileClassifier.classify(text: text, profiles: candidates) else {
            classifierLogger.info("base=\(baseLang, privacy: .public) but no marker matches")
            return nil
        }
        classifierLogger.info("classified: base=\(baseLang, privacy: .public) profile=\(result.profileId, privacy: .public) confidence=\(result.confidence, format: .fixed(precision: 2))")
        return result
    }
}
