import Foundation
import JavaScriptCore
import os

/// One loaded plugin, exposing the contract-shaped `search` / `download` API.
///
/// Wraps a `PluginHost` (the JSContext + bindings) and lifts JS-side dicts
/// into typed Swift values. `@MainActor` because `PluginHost` is.
@MainActor
final class PluginSource: Identifiable {
    /// Unique within the plugins directory. Prefer the manifest's `id` when
    /// the plugin declares one; otherwise fall back to the filename without
    /// extension (legacy contract). Used as the `pluginID` stamped on results
    /// so downloads route back here.
    let id: String
    let displayName: String
    /// Pulled from the plugin's optional `const manifest = { … }` block.
    /// `nil` for legacy plugins that ship no manifest — registry/update
    /// features are unavailable for those.
    let manifest: PluginManifest?
    private let host: PluginHost

    /// Instantiates a host from already-read JS source. Splitting file I/O
    /// from host construction lets `PluginDirectory.readAllPluginSources`
    /// hit disk off-main while keeping `PluginHost` (and its `JSContext`)
    /// pinned to MainActor.
    ///
    /// `fallbackID` is the filename without extension — used when the plugin
    /// ships no manifest (legacy plugins authored before manifests existed).
    init(fallbackID: String, source: String) throws {
        self.host = try PluginHost(pluginSource: source)
        self.manifest = host.manifest
        self.id = host.manifest?.id ?? fallbackID
        self.displayName = host.manifest?.name ?? fallbackID
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
            guard let urlString = value.toString(),
                !urlString.isEmpty,
                let url = URL(string: urlString)
            else {
                throw PluginError.runtime("plugin download() returned invalid URL string")
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
            if let urlString, !urlString.isEmpty, let url = URL(string: urlString) {
                return .browser(url)
            }
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
    static func readAllPluginSources() -> (sources: [LoadedPluginSource], firstError: Error?) {
        var sources: [LoadedPluginSource] = []
        var firstError: Error?
        for url in availablePluginURLs() {
            let fallbackID = url.deletingPathExtension().lastPathComponent
            do {
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

    /// First-launch fallback: copies plugins bundled in `Resources/Plugins/`
    /// into the user's plugins directory the *first* time the directory is
    /// empty and no install records exist. This guarantees `gutenberg`
    /// without a network call — the legit-only seed when the user has no
    /// connectivity on day one.
    ///
    /// Subsequent launches are no-ops: the install records ledger marks the
    /// seeded plugins as `.bundled`, and from then on the registry is the
    /// canonical source. A user who clicks Update on `gutenberg` upgrades
    /// the record from `.bundled` to `.registry` automatically.
    ///
    /// User-authored plugins are untouched. Failures are silent: if the
    /// bundle ships nothing, or the destination dir can't be created, the
    /// user just sees an empty plugins list (matching the "no plugins"
    /// state).
    static func seedBundledIfNeeded() {
        guard let dir = directoryURL() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Skip when the user already has plugin state of any kind. Two
        // independent signals so a partially-corrupted state can't trick
        // us into reseeding.
        let alreadyHaveJS = !availablePluginURLs().isEmpty
        let alreadyHaveRecords = !PluginInstallRecords.read().isEmpty
        guard !alreadyHaveJS, !alreadyHaveRecords else { return }

        // Xcode 16's synchronized file groups flatten the Resources/Plugins
        // folder into the bundle root, so look up `.js` at top-level.
        guard
            let bundleURLs = Bundle.main.urls(
                forResourcesWithExtension: "js", subdirectory: nil)
        else { return }

        for bundleURL in bundleURLs {
            let dest = dir.appending(path: bundleURL.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: bundleURL, to: dest)
            } catch {
                pluginLogger.error(
                    "bundled seed failed for \(bundleURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Returns the bundle's `.js` URLs (read-only access to the seed source).
    /// Used during install-record reconciliation so a plugin file whose bytes
    /// match the shipped seed gets recorded as `.bundled` (vs `.manual`).
    static func bundledPluginURLs() -> [URL] {
        Bundle.main.urls(forResourcesWithExtension: "js", subdirectory: nil) ?? []
    }

    /// Writes `<id>.js` into the plugins directory atomically. Caller
    /// guarantees `id` is filename-safe (registry ids are constrained).
    /// Refuses to clobber an existing file unless `replace` is true — for
    /// install we refuse (don't surprise the user), for update we replace.
    static func writePluginFile(
        id: String,
        bytes: Data,
        replace: Bool
    ) throws -> URL {
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

    /// Deletes `<id>.js` and the corresponding install record. Best-effort:
    /// missing files are not an error (the caller's intent is "gone").
    static func deletePluginFile(id: String) throws {
        guard let dir = directoryURL() else { return }
        let dest = dir.appending(path: "\(id).js")
        if FileManager.default.fileExists(atPath: dest.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: dest)
        }
        PluginInstallRecords.remove(id: id)
    }

    /// After a reload, ensure every loaded plugin has an install record.
    /// Missing records are inferred: byte-equal to a bundled file → `.bundled`;
    /// otherwise `.manual`. Plugins that have an explicit record (already
    /// `.registry` or `.bundled`) are left alone.
    ///
    /// Runs on MainActor so it can read each plugin's manifest (`id`, `version`).
    /// The file I/O part is cheap (the plugins are already cached by the OS
    /// from the reload).
    @MainActor
    static func reconcileInstallRecords(for plugins: [PluginSource]) {
        let existing = PluginInstallRecords.read()
        let bundledBytes: [String: Data] = Dictionary(
            uniqueKeysWithValues: bundledPluginURLs().compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return (url.deletingPathExtension().lastPathComponent, data)
            }
        )
        guard let dir = directoryURL() else { return }

        for plugin in plugins {
            if existing[plugin.id] != nil { continue }
            let dest = dir.appending(path: "\(plugin.id).js")
            let bytes = try? Data(contentsOf: dest)
            let sha = bytes.map(sha256Hex)
            let isBundled =
                bytes != nil
                && bundledBytes.values.contains(where: { $0 == bytes })
            PluginInstallRecords.upsert(
                PluginInstallRecord(
                    id: plugin.id,
                    source: isBundled ? .bundled : .manual,
                    registryURL: nil,
                    // installedVersion stays nil for legacy / manual /
                    // bundled-pre-registry plugins. Updated to the
                    // registry's version on the first registry-driven
                    // update.
                    installedVersion: nil,
                    sha256: sha,
                    installedAt: Date()
                )
            )
        }
    }
}
