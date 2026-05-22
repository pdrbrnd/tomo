import Foundation
import JavaScriptCore
import os

/// One loaded plugin, exposing the contract-shaped `search` / `download` API.
///
/// Wraps a `PluginHost` (the JSContext + bindings) and lifts JS-side dicts
/// into typed Swift values. `@MainActor` because `PluginHost` is.
@MainActor
final class PluginSource: Identifiable {
    /// Unique within the plugins directory (= filename without extension).
    /// Used as the `pluginID` stamped on results so downloads route back here.
    let id: String
    let displayName: String
    private let host: PluginHost

    /// Instantiates a host from already-read JS source. Splitting file I/O
    /// from host construction lets `PluginDirectory.readAllPluginSources`
    /// hit disk off-main while keeping `PluginHost` (and its `JSContext`)
    /// pinned to MainActor.
    init(displayName: String, source: String) throws {
        self.host = try PluginHost(pluginSource: source)
        self.displayName = displayName
        self.id = displayName
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

    /// Calls the plugin's `download(result)` and returns the URL the plugin
    /// claims is downloadable. The caller fetches and persists.
    func download(_ result: PluginResult) async throws -> URL {
        let value = try await host.invokePromise(
            "download", argsAsJS: [result.toJSDictionary()])
        guard let urlString = value.toString(),
            !urlString.isEmpty,
            let url = URL(string: urlString)
        else {
            throw PluginError.invalidResponse
        }
        return url
    }
}

/// Filesystem layout for plugins: `~/Library/Application Support/com.pdrbrnd.tomo/plugins/`.
/// The folder is the source of truth: every `.js` at that path is a candidate
/// plugin. Spike loads the first one (alphabetical) — multi-plugin merging is
/// productionisation work.
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

    /// One plugin's display name + JS source, ready to feed into `PluginSource`
    /// on MainActor. `Sendable` so the array can cross actor boundaries when
    /// `readAllPluginSources` runs detached.
    struct LoadedPluginSource: Sendable {
        let displayName: String
        let source: String
    }

    /// Reads every `.js` file in the plugins directory off-main. Returns the
    /// successfully-read sources plus the first read error (if any) — JS
    /// parsing happens later in `loadAllPlugins(from:)` on MainActor.
    static func readAllPluginSources() -> (sources: [LoadedPluginSource], firstError: Error?) {
        var sources: [LoadedPluginSource] = []
        var firstError: Error?
        for url in availablePluginURLs() {
            let displayName = url.deletingPathExtension().lastPathComponent
            do {
                let source = try String(contentsOf: url, encoding: .utf8)
                sources.append(LoadedPluginSource(displayName: displayName, source: source))
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
                    try PluginSource(displayName: entry.displayName, source: entry.source)
                )
            } catch {
                pluginLogger.error(
                    "loading \(entry.displayName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                if firstError == nil { firstError = error }
            }
        }
        return (plugins, firstError)
    }

    /// Copies any plugins bundled in `Resources/Plugins/` into the user's
    /// plugins directory the first time the app runs. Idempotent via a
    /// `UserDefaults` flag — removing a seeded plugin later won't bring
    /// it back. Failures are silent: if the bundle ships nothing, or the
    /// destination dir can't be created, the user just sees an empty
    /// plugins list (matching the "no plugins" state).
    static func seedBundledPluginsIfNeeded() {
        let key = "didSeedDefaultPlugins"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        defer { UserDefaults.standard.set(true, forKey: key) }

        // Xcode 16's synchronized file groups flatten the Resources/Plugins
        // folder into the bundle root, so look up `.js` at top-level.
        guard let dir = directoryURL(),
            let bundleURLs = Bundle.main.urls(
                forResourcesWithExtension: "js", subdirectory: nil)
        else { return }

        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)

        for bundleURL in bundleURLs {
            let dest = dir.appending(path: bundleURL.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: dest.path(percentEncoded: false))
            else { continue }
            try? FileManager.default.copyItem(at: bundleURL, to: dest)
        }
    }
}
