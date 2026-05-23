import Foundation

/// Single source of truth for the running app's marketing version
/// (`CFBundleShortVersionString` — e.g. `"1.0"`, `"1.5.2"`).
///
/// Used by the plugin install/update flow to gate on `minAppVersion`
/// declared by plugins. Read once at access; the Info.plist doesn't
/// change at runtime.
nonisolated enum AppVersion {
    /// Marketing version string, e.g. `"1.0"`. Defaults to `"0.0"` if the
    /// key is missing (shouldn't happen in a built app — this is the
    /// "tests under a target without the key" safety net).
    static let current: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }()
}
