import Foundation

/// Persists the set of language-profile IDs the user has switched off in
/// Settings. Disabled profiles are excluded from auto-classification on
/// import; they remain visible in the manual locale picker.
nonisolated enum DisabledProfilesStore {
    static let key = "disabledLanguageProfiles"

    static func load(from defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    static func save(_ ids: Set<String>, to defaults: UserDefaults = .standard) {
        defaults.set(Array(ids).sorted(), forKey: key)
    }
}
