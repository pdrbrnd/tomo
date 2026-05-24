import Foundation
import JavaScriptCore
import os

/// One loaded plugin, exposing the contract-shaped `search` / `download` API.
///
/// Wraps a `PluginHost` (the JSContext + bindings) and lifts JS-side dicts
/// into typed Swift values. `@MainActor` because `PluginHost` is.
@MainActor
final class PluginSource: Identifiable {
    /// Manifest's `id` when declared; filename without extension otherwise.
    /// Stamped on `PluginResult.pluginID` so downloads route back here.
    let id: String
    let displayName: String
    let manifest: PluginManifest?
    /// sha256 of the .js bytes — the change signal compared against registry
    /// entries to detect updates without a separate install ledger.
    let sha256: String
    private let host: PluginHost

    /// `fallbackID` is the filename without extension — used when the plugin
    /// ships no manifest.
    init(fallbackID: String, source: String) throws {
        self.host = try PluginHost(pluginSource: source)
        self.manifest = host.manifest
        self.id = host.manifest?.id ?? fallbackID
        self.displayName = host.manifest?.name ?? fallbackID
        self.sha256 = sha256Hex(source)
    }

    /// Calls the plugin's `search(query)` and lifts results, stamping
    /// `pluginID` on each so downloads route back to this plugin.
    /// Caller is expected to debounce; this fires immediately.
    func search(_ query: PluginQuery) async throws -> [PluginResult] {
        let value = try await host.invokePromise(
            "search", argsAsJS: [query.toJSDictionary()])
        guard let arr = value.toArray() as? [[String: Any]] else {
            throw PluginError.invalidResponse
        }
        let pluginID = self.id
        return arr.compactMap { dict in
            PluginResult.from(jsValue: dict, pluginID: pluginID)
        }
    }

    /// Calls the plugin's `download(result)` and lifts the JS return value
    /// into a typed outcome:
    ///
    /// - String → `.url(_)` — host fetches directly. Existing behavior.
    /// - `{ kind: "browser", url?: string }` → `.browser(_)` — host opens
    ///   the in-app browser sheet. Falls back to `result.detailURL` when
    ///   the plugin omits `url`.
    func download(_ result: PluginResult) async throws -> PluginDownloadOutcome {
        let value = try await host.invokePromise(
            "download", argsAsJS: [result.toJSDictionary()])
        return try parseDownloadOutcome(value, fallbackBrowserURL: result.detailURL)
    }

    private func parseDownloadOutcome(
        _ value: JSValue,
        fallbackBrowserURL: URL?
    ) throws -> PluginDownloadOutcome {
        if value.isString {
            guard let urlString = value.toString(), !urlString.isEmpty else {
                throw PluginError.runtime("plugin download() returned invalid URL string")
            }
            let url: URL
            do {
                url = try PluginURLValidator.validateNetworkURL(urlString)
            } catch {
                throw PluginError.runtime("plugin download() URL rejected: \(error.localizedDescription)")
            }
            return .url(url)
        }
        if value.isObject {
            guard let kindValue = value.forProperty("kind"),
                !kindValue.isUndefined,
                !kindValue.isNull,
                let kind = kindValue.toString()
            else {
                throw PluginError.runtime("plugin download() returned object without 'kind'")
            }
            guard kind == "browser" else {
                throw PluginError.runtime("plugin download() returned unknown kind: '\(kind)'")
            }
            // `url` is optional — fall back to result.detailURL when missing.
            let urlValue = value.forProperty("url")
            let urlString =
                (urlValue?.isString == true) ? urlValue?.toString() : nil
            if let urlString, !urlString.isEmpty {
                do {
                    let url = try PluginURLValidator.validateNetworkURL(urlString)
                    return .browser(url)
                } catch {
                    throw PluginError.runtime("plugin browser URL rejected: \(error.localizedDescription)")
                }
            }
            // `fallbackBrowserURL` is `result.detailURL`, already validated at
            // PluginResult parse time, so no re-check needed here.
            if let fallback = fallbackBrowserURL {
                return .browser(fallback)
            }
            throw PluginError.runtime(
                "plugin returned { kind: 'browser' } without url and result has no detailURL"
            )
        }
        throw PluginError.invalidResponse
    }
}

/// Lifted from a plugin's `download(result)` return value. Plugins return
/// either a string URL (host fetches directly) or `{ kind: "browser", url? }`
/// (host opens the in-app browser sheet — used for sources that gate downloads
/// behind Cloudflare or countdown timers).
enum PluginDownloadOutcome: Sendable {
    case url(URL)
    case browser(URL)
}

/// Filesystem layout for plugins: `~/Library/Application Support/com.pdrbrnd.tomo/plugins/`.
/// The folder is the source of truth: every `.js` at that path is a candidate
/// plugin. All discovered plugins are loaded; per-plugin enable/disable lives
/// in the sources popover (persisted in `UserDefaults`).
///
/// `nonisolated` so disk reads and bundle seeding can run from `Task.detached`
/// during `AppState.bootstrap`. The MainActor-only step (constructing
/// `PluginSource` from pre-read JS) is `loadAllPlugins(from:)`.
nonisolated enum PluginDirectory {
    /// Maximum plugin source size. Even a heavyweight scraper with a tucked-in
    /// vendor lib fits in a few hundred KB; 2 MB is comically generous and
    /// blocks the "ship a huge payload" abuse path at install time and on
    /// every cold-load read.
    static let maxPluginBytes = 2 * 1024 * 1024

    static func directoryURL() -> URL? {
        guard
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else { return nil }
        return
            appSupport
            .appending(path: "com.pdrbrnd.tomo", directoryHint: .isDirectory)
            .appending(path: "plugins", directoryHint: .isDirectory)
    }

    /// Lists every `.js` file in the plugins directory, alphabetically.
    /// Empty list when the directory is missing or empty.
    static func availablePluginURLs() -> [URL] {
        guard let dir = directoryURL(),
            let contents = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        else { return [] }
        return
            contents
            .filter { $0.pathExtension.lowercased() == "js" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// One plugin's filename-derived id + JS source, ready to feed into
    /// `PluginSource` on MainActor. `Sendable` so the array can cross actor
    /// boundaries when `readAllPluginSources` runs detached.
    struct LoadedPluginSource: Sendable {
        /// Filename without `.js`. Used as the plugin id when the JS ships
        /// no `manifest`. Once the manifest is read on MainActor, the
        /// manifest's `id` wins.
        let fallbackID: String
        let source: String
    }

    /// Reads every `.js` file in the plugins directory off-main. Returns the
    /// successfully-read sources plus the first read error (if any) — JS
    /// parsing happens later in `loadAllPlugins(from:)` on MainActor.
    /// Skips files over `maxPluginBytes` — defence against a malicious or
    /// runaway file already on disk.
    static func readAllPluginSources() -> (sources: [LoadedPluginSource], firstError: Error?) {
        var sources: [LoadedPluginSource] = []
        var firstError: Error?
        for url in availablePluginURLs() {
            let fallbackID = url.deletingPathExtension().lastPathComponent
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
                let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
                if size > maxPluginBytes {
                    pluginLogger.error(
                        "skipping \(url.lastPathComponent, privacy: .public): \(size) bytes > \(maxPluginBytes) cap"
                    )
                    if firstError == nil {
                        firstError = PluginError.loadFailed(
                            "\(url.lastPathComponent) is \(size) bytes — exceeds \(maxPluginBytes / 1024 / 1024) MB plugin cap"
                        )
                    }
                    continue
                }
                let source = try String(contentsOf: url, encoding: .utf8)
                sources.append(LoadedPluginSource(fallbackID: fallbackID, source: source))
            } catch {
                pluginLogger.error(
                    "reading \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                if firstError == nil {
                    firstError = PluginError.loadFailed(
                        "could not read \(url.lastPathComponent): \(error.localizedDescription)"
                    )
                }
            }
        }
        return (sources, firstError)
    }

    /// Instantiates a `PluginSource` for each pre-read JS source. Runs on
    /// MainActor because `PluginSource` / `PluginHost` are `@MainActor` (the
    /// underlying `JSContext` is single-threaded). Continues past individual
    /// failures so one broken plugin doesn't take down the rest.
    @MainActor
    static func loadAllPlugins(
        from sources: [LoadedPluginSource]
    ) -> (plugins: [PluginSource], firstError: Error?) {
        var plugins: [PluginSource] = []
        var firstError: Error?
        for entry in sources {
            do {
                plugins.append(
                    try PluginSource(fallbackID: entry.fallbackID, source: entry.source)
                )
            } catch {
                pluginLogger.error(
                    "loading \(entry.fallbackID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                if firstError == nil { firstError = error }
            }
        }
        return (plugins, firstError)
    }

    /// Writes `<id>.js` into the plugins directory atomically. Refuses to
    /// clobber an existing file unless `replace` is true (install refuses;
    /// update replaces). Refuses files over `maxPluginBytes`.
    static func writePluginFile(
        id: String,
        bytes: Data,
        replace: Bool
    ) throws -> URL {
        guard bytes.count <= maxPluginBytes else {
            throw PluginError.loadFailed(
                "plugin source is \(bytes.count) bytes — exceeds \(maxPluginBytes / 1024 / 1024) MB cap"
            )
        }
        guard let dir = directoryURL() else {
            throw PluginError.loadFailed("plugins directory unavailable")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(path: "\(id).js")
        let exists = FileManager.default.fileExists(atPath: dest.path(percentEncoded: false))
        if exists && !replace {
            throw PluginError.loadFailed(
                "A plugin file named \(id).js already exists. Remove it first.")
        }
        if exists {
            try FileManager.default.removeItem(at: dest)
        }
        try bytes.write(to: dest, options: .atomic)
        return dest
    }

    /// Best-effort: a missing file is not an error.
    static func deletePluginFile(id: String) throws {
        guard let dir = directoryURL() else { return }
        let dest = dir.appending(path: "\(id).js")
        if FileManager.default.fileExists(atPath: dest.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: dest)
        }
    }
}
