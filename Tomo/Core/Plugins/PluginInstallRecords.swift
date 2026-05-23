import Foundation
import os

nonisolated enum PluginInstallSource: String, Codable, Sendable, Hashable {
    case registry
    case bundled
    case manual
}

nonisolated struct PluginInstallRecord: Codable, Sendable, Hashable {
    let id: String
    let source: PluginInstallSource
    let registryURL: URL?
    let installedVersion: String?
    let sha256: String?
    let installedAt: Date
}

/// `<plugins-dir>/.tomo/installed.json` — the "where did each .js come from"
/// ledger. Mirrors the `<library>/.tomo/collections.json` convention.
/// Reads return an empty map when the file is missing; install records are
/// advisory and never block a plugin from loading.
nonisolated enum PluginInstallRecords {
    static func fileURL() -> URL? {
        guard let dir = PluginDirectory.directoryURL() else { return nil }
        return
            dir
            .appending(path: ".tomo", directoryHint: .isDirectory)
            .appending(path: "installed.json")
    }

    static func read() -> [String: PluginInstallRecord] {
        guard let url = fileURL(),
            let data = try? Data(contentsOf: url)
        else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let file = try decoder.decode(InstallFile.self, from: data)
            return Dictionary(uniqueKeysWithValues: file.installed.map { ($0.id, $0) })
        } catch {
            pluginLogger.error(
                "install records read failed: \(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
    }

    static func write(_ records: [String: PluginInstallRecord]) {
        guard let url = fileURL() else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let file = InstallFile(
                version: 1,
                installed: records.values.sorted { $0.id < $1.id }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(file).write(to: url, options: .atomic)
        } catch {
            pluginLogger.error(
                "install records write failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

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

    /// Carries a schema `version` alongside the records for forward-compat.
    private struct InstallFile: Codable {
        let version: Int
        let installed: [PluginInstallRecord]
    }
}
