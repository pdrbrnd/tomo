import Foundation
import JavaScriptCore

/// Metadata a plugin self-declares via a top-level `const manifest = { ... }`
/// in its .js file. Read once after `JSContext.evaluateScript`. Only `id`
/// is required; everything else is optional. Plugins that ship no manifest
/// still load — they just can't participate in registry-driven update
/// tracking.
///
/// Notably absent: `version`. The plugin's "version" is registry-side
/// metadata (an ISO timestamp the build script extracts from git), not a
/// claim the plugin author has to remember to bump. The plugin author *can*
/// declare `minAppVersion` to gate install/update on host compatibility
/// (Obsidian's convention).
struct PluginManifest: Sendable, Hashable {
    let id: String
    let name: String
    let description: String?
    let homepage: URL?
    let author: String?
    let license: String?
    /// Minimum host app version this plugin is known to work with. Semver
    /// string (e.g. `"1.2.0"`). Compared against the running app's version
    /// at install/update time; mismatches refuse with a clear message.
    /// `nil` means no constraint (legacy plugins predating this field).
    let minAppVersion: String?

    /// Reads the `manifest` declaration from a JSContext (after the plugin's
    /// source has been evaluated) and lifts it into a Swift struct. Returns
    /// nil if the declaration is missing, malformed, or lacks the required
    /// `id` field. `name` falls back to `id` when absent.
    ///
    /// We evaluate `manifest` rather than `objectForKeyedSubscript("manifest")`
    /// because top-level `const`/`let` declarations don't become properties
    /// of the JS global object; only `var` and `function` do. The `typeof`
    /// guard handles the legacy "no manifest at all" case without throwing
    /// a ReferenceError.
    static func from(jsContext ctx: JSContext) -> PluginManifest? {
        let value = ctx.evaluateScript(
            "typeof manifest !== 'undefined' ? manifest : null"
        )
        guard let value, !value.isUndefined, !value.isNull, value.isObject else { return nil }
        return from(jsValue: value)
    }

    static func from(jsValue value: JSValue) -> PluginManifest? {
        guard value.isObject else { return nil }
        guard let id = string(value, "id"), !id.isEmpty else { return nil }
        let name = string(value, "name") ?? id
        let description = string(value, "description")
        let homepage = string(value, "homepage").flatMap(URL.init(string:))
        let author = string(value, "author")
        let license = string(value, "license")
        let minAppVersion = string(value, "minAppVersion")
        return PluginManifest(
            id: id,
            name: name,
            description: description,
            homepage: homepage,
            author: author,
            license: license,
            minAppVersion: minAppVersion
        )
    }

    private static func string(_ value: JSValue, _ key: String) -> String? {
        let v = value.forProperty(key)
        guard let v, !v.isUndefined, !v.isNull, v.isString else { return nil }
        let s = v.toString()
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

/// Compares two semantic version strings. Returns `.orderedAscending` when
/// `lhs < rhs`, etc. Non-numeric segments compare lexically; missing trailing
/// segments are treated as zero ("1.0" == "1.0.0"). Good enough for the
/// "is there an update?" check we actually need — not a full semver impl.
nonisolated enum SemVerCompare {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = parts(lhs)
        let b = parts(rhs)
        let n = max(a.count, b.count)
        for i in 0..<n {
            let ai = i < a.count ? a[i] : "0"
            let bi = i < b.count ? b[i] : "0"
            if let ax = Int(ai), let bx = Int(bi) {
                if ax < bx { return .orderedAscending }
                if ax > bx { return .orderedDescending }
            } else {
                let r = ai.compare(bi)
                if r != .orderedSame { return r }
            }
        }
        return .orderedSame
    }

    private static func parts(_ s: String) -> [String] {
        s.split(separator: ".").map(String.init)
    }
}
