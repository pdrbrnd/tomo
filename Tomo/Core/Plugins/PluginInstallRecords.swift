import Foundation
import os

/// Where a plugin file in the plugins directory came from. Lets the Plugins
/// settings surface "Update" only on registry-installed plugins (manual files
/// are the user's own responsibility) and "First-launch fallback" badging on
/// bundled-only installs.
nonisolated enum PluginInstallSource: String, Codable, Sendable, Hashable {
    /// Installed via "Browse" from a registry. `registryURL` is set; updates
    /// flow from there.
    case registry
    /// Seeded from the bundled `Resources/Plugins/` copy on first launch
    /// (offline-safe fallback). Upgrades to `.registry` the moment a registry
    /// install/update replaces the file.
    case bundled
    /// File-drop install (NSOpenPanel) or any other manually-placed `.js`.
    /// Tomo never auto-updates these.
    case manual
}

/// One row in the install ledger. Persisted as JSON so the plugins folder
/// survives an app reinstall without losing where each plugin came from.
nonisolated struct PluginInstallRecord: Codable, Sendable, Hashable {
    let id: String
    let source: PluginInstallSource
    /// Registry the plugin was installed from. nil for `.bundled` / `.manual`.
    let registryURL: URL?
    /// Manifest version at install time. nil when the plugin shipped no
    /// manifest — registry update tracking is unavailable for those.
    let installedVersion: String?
    /// sha256 of the .js bytes at install time. Used to detect local edits
    /// before clobbering the file on update.
    let sha256: String?
    let installedAt: Date
}

/// Ledger for "what's installed and where did it come from." Mirrors the
/// `<library>/.tomo/collections.json` convention: a hidden sidecar at the
/// root of the directory it describes.
///
/// `nonisolated` so disk I/O can run from `Task.detached`. Reads return an
/// empty map when the file is missing; writes create the `.tomo/` directory
/// on demand. Atomic writes via `Data.write(.atomic)`.
nonisolated enum PluginInstallRecords {
    /// `<plugins-dir>/.tomo/installed.json`. Returns nil when the plugins
    /// directory itself isn't resolvable (no Application Support).
    static func fileURL() -> URL? {
        guard let dir = PluginDirectory.directoryURL() else { return nil }
        return
            dir
            .appending(path: ".tomo", directoryHint: .isDirectory)
            .appending(path: "installed.json")
    }

    /// All install records, keyed by plugin id. Empty when the file is
    /// missing or unreadable — install records are advisory, never a hard
    /// dependency for the plugin to load.
    static func read() -> [String: PluginInstallRecord] {
        guard let url = fileURL(),
            let data = try? Data(contentsOf: url)
        else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let file = try decoder.decode(InstallFile.self, from: data)
            var map: [String: PluginInstallRecord] = [:]
            for record in file.installed {
                map[record.id] = record
            }
            return map
        } catch {
            pluginLogger.error(
                "install records read failed: \(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
    }

    static func write(_ records: [String: PluginInstallRecord]) {
        guard let url = fileURL() else { return }
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true)
            let file = InstallFile(
                version: 1,
                installed: records.values.sorted { $0.id < $1.id }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(file)
            try data.write(to: url, options: .atomic)
        } catch {
            pluginLogger.error(
                "install records write failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Upserts one record and persists. Convenience over read-modify-write
    /// at every call site.
    static func upsert(_ record: PluginInstallRecord) {
        var all = read()
        all[record.id] = record
        write(all)
    }

    static func remove(id: String) {
        var all = read()
        guard all.removeValue(forKey: id) != nil else { return }
        write(all)
    }

    /// Top-level shape so we can carry a schema `version` alongside the
    /// records. Plain `[InstallRecord]` would lock us out of forward-compat.
    private struct InstallFile: Codable {
        let version: Int
        let installed: [PluginInstallRecord]
    }
}
