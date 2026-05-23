import Foundation
import JavaScriptCore

/// Metadata a plugin self-declares via a top-level `const manifest = { ... }`.
/// Only `id` is required; the rest are optional. Plugins without a manifest
/// still load. See `docs/plugins.md` for the field semantics.
struct PluginManifest: Sendable, Hashable {
    let id: String
    let name: String
    let description: String?
    let homepage: URL?
    let author: String?
    let license: String?
    let minAppVersion: String?

    /// `evaluateScript("manifest")` rather than `objectForKeyedSubscript`
    /// because top-level `const`/`let` declarations don't land on the JS
    /// global object — only `var` and `function` do. The `typeof` guard
    /// keeps "no manifest at all" from throwing a ReferenceError.
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
/// segments are treated as zero ("1.0" == "1.0.0"). Good enough for
/// `minAppVersion` gating — *not* a full semver impl; pre-release tags
/// (`"1.0.0-beta"`) sort wrong (lexically beta < release).
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

/// Compares plugin version strings (ISO-8601 timestamps the registry build
/// script writes). Parses both as `Date`; falls back to lex compare if
/// either side isn't a recognizable timestamp, so a legacy registry that
/// stores a different shape doesn't silently misbehave.
nonisolated enum PluginVersion {
    static func updateAvailable(installed: String, available: String) -> Bool {
        if let i = parse(installed), let a = parse(available) {
            return i < a
        }
        return installed < available
    }

    // ISO8601DateFormatter instances are thread-safe per Apple docs;
    // `nonisolated(unsafe)` lets us share one across actors safely.
    nonisolated(unsafe) private static let parser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parse(_ s: String) -> Date? { parser.date(from: s) }
}
