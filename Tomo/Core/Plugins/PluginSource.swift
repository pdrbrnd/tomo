import Foundation
import JavaScriptCore

/// One loaded plugin, exposing the contract-shaped `search` / `download` API.
///
/// Wraps a `PluginHost` (the JSContext + bindings) and lifts JS-side dicts
/// into typed Swift values. `@MainActor` because `PluginHost` is.
@MainActor
final class PluginSource {
    let displayName: String
    private let host: PluginHost

    /// Loads `pluginPath` as a JS source file and instantiates a host. Throws
    /// `PluginError.loadFailed` if the file can't be read, parsed, or doesn't
    /// expose the required `search` / `download` functions.
    init(displayName: String, pluginPath: URL) throws {
        let source: String
        do {
            source = try String(contentsOf: pluginPath, encoding: .utf8)
        } catch {
            throw PluginError.loadFailed(
                "could not read \(pluginPath.lastPathComponent): \(error.localizedDescription)")
        }
        self.host = try PluginHost(pluginSource: source)
        self.displayName = displayName
    }

    /// Calls the plugin's `search(query)` and lifts results.
    /// Caller is expected to debounce; this fires immediately.
    func search(_ query: PluginQuery) async throws -> [PluginResult] {
        let value = try await host.invokePromise(
            "search", argsAsJS: [query.toJSDictionary()])
        guard let arr = value.toArray() as? [[String: Any]] else {
            throw PluginError.invalidResponse
        }
        return arr.compactMap(PluginResult.from(jsValue:))
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
enum PluginDirectory {
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

    /// Loads the first plugin found in the directory. Returns nil when the
    /// directory has no `.js` files. Throws `PluginError` if the file is
    /// present but fails to parse — caller surfaces a toast.
    static func loadFirstPlugin() throws -> PluginSource? {
        guard let url = availablePluginURLs().first else { return nil }
        let displayName = url.deletingPathExtension().lastPathComponent
        return try PluginSource(displayName: displayName, pluginPath: url)
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
