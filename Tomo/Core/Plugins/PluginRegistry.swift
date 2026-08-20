import CryptoKit
import Foundation

/// One plugin listed in a registry. `version` is an ISO-8601 timestamp the
/// registry's build script derives from git mtime — plugin authors never
/// set it. `sha256` is verified at download time. New optional fields can
/// be added without breaking older clients.
nonisolated struct PluginRegistryEntry: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let name: String
    let version: String
    let description: String?
    let homepage: URL?
    let author: String?
    let license: String?
    let minAppVersion: String?
    let url: URL
    let sha256: String
}

/// Schema-versioned so older clients can bail out on an unknown `version`.
nonisolated struct PluginRegistryFile: Codable, Sendable, Hashable {
    let version: Int
    let name: String
    let plugins: [PluginRegistryEntry]
}

/// Cached registry response + conditional-GET headers, kept together so the
/// cache survives a launch without a separate keyed store.
nonisolated struct CachedRegistry: Codable, Sendable, Hashable {
    let registryURL: URL
    let registry: PluginRegistryFile
    let etag: String?
    let lastModified: String?
    let fetchedAt: Date
}

enum PluginRegistryError: Error, LocalizedError, Sendable {
    case invalidURL
    case http(Int)
    case decode(String)
    case sha256Mismatch(expected: String, actual: String)
    case unsupportedSchemaVersion(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid registry URL."
        case .http(let s): "Registry HTTP \(s)"
        case .decode(let m): "Registry parse error: \(m)"
        case .sha256Mismatch(let e, let a): "sha256 mismatch — expected \(e.prefix(8))…, got \(a.prefix(8))…"
        case .unsupportedSchemaVersion(let v): "Unsupported registry schema (v\(v))."
        }
    }
}

/// Reads / writes the user's registry URL list and per-URL cached responses.
/// Network calls are explicit (`fetch...`) — nothing here runs on launch.
nonisolated enum PluginRegistryStore {
    /// A registry that ships with the app. `fallbackName` labels the
    /// settings row before the registry has ever been fetched (after a
    /// fetch the registry's own `name` wins).
    nonisolated struct BuiltInRegistry: Sendable, Hashable {
        let fallbackName: String
        let url: URL
    }

    /// The registries baked into the app. Hardcoded; always present in
    /// `allRegistryURLs` regardless of the user-added list. Users can't
    /// remove them from settings (only ignore their plugins). Each
    /// registry is hosted and versioned independently.
    static let builtInRegistries: [BuiltInRegistry] = [
        BuiltInRegistry(
            fallbackName: "Tomo Official Plugins",
            url: URL(
                string: "https://raw.githubusercontent.com/pdrbrnd/tomo-plugins/main/registry.json"
            )!),
        BuiltInRegistry(
            fallbackName: "Tomo Extras",
            url: URL(string: "https://extras.tomolibrary.com/registry.json")!),
    ]

    static var builtInRegistryURLs: [URL] { builtInRegistries.map(\.url) }

    private static let userAddedRegistriesKey = "pluginRegistries"

    static func userAddedRegistryURLs() -> [URL] {
        guard let raw = UserDefaults.standard.array(forKey: userAddedRegistriesKey) as? [String]
        else { return [] }
        return raw.compactMap(URL.init(string:))
    }

    static func setUserAddedRegistryURLs(_ urls: [URL]) {
        UserDefaults.standard.set(urls.map(\.absoluteString), forKey: userAddedRegistriesKey)
    }

    /// Built-in registries first, then user-added, deduped while preserving
    /// order. Iteration order matches the Plugins settings UI.
    static func allRegistryURLs() -> [URL] {
        var seen = Set<URL>()
        var out: [URL] = []
        for url in builtInRegistryURLs + userAddedRegistryURLs() {
            if seen.insert(url).inserted { out.append(url) }
        }
        return out
    }

    // MARK: - Cache

    /// `~/Library/Application Support/com.pdrbrnd.tomo/registry-cache/`.
    /// Separate from the plugins directory so a "rebuild plugin state from
    /// scratch" never accidentally clobbers cached registry data, and so
    /// the cache survives a "Reveal Plugins Folder → drag all .js out" by
    /// the user.
    static func cacheDirectoryURL() -> URL? {
        guard
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else { return nil }
        return
            appSupport
            .appending(path: "com.pdrbrnd.tomo", directoryHint: .isDirectory)
            .appending(path: "registry-cache", directoryHint: .isDirectory)
    }

    private static func cacheFileURL(for registryURL: URL) -> URL? {
        guard let dir = cacheDirectoryURL() else { return nil }
        return dir.appending(path: "\(sha256Hex(registryURL.absoluteString)).json")
    }

    static func cachedRegistry(at registryURL: URL) -> CachedRegistry? {
        guard let url = cacheFileURL(for: registryURL),
            let data = try? Data(contentsOf: url)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CachedRegistry.self, from: data)
    }

    static func writeCachedRegistry(_ cached: CachedRegistry) throws {
        guard let dir = cacheDirectoryURL(),
            let url = cacheFileURL(for: cached.registryURL)
        else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(cached)
        try data.write(to: url, options: .atomic)
    }

    static func removeCachedRegistry(at registryURL: URL) {
        guard let url = cacheFileURL(for: registryURL) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Network

    /// Fetches the registry JSON, parses it, writes to cache, returns the
    /// fresh snapshot. Uses ETag / If-Modified-Since for conditional GETs;
    /// a 304 returns the previously-cached value unchanged. Errors propagate
    /// so callers can surface them as toasts.
    static func fetchRegistry(at registryURL: URL) async throws -> CachedRegistry {
        var req = URLRequest(url: registryURL)
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let existing = cachedRegistry(at: registryURL)
        if let etag = existing?.etag {
            req.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = existing?.lastModified {
            req.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        if status == 304, let existing {
            return existing
        }
        guard (200..<300).contains(status) else {
            throw PluginRegistryError.http(status)
        }

        let file: PluginRegistryFile
        do {
            file = try JSONDecoder().decode(PluginRegistryFile.self, from: data)
        } catch {
            throw PluginRegistryError.decode(error.localizedDescription)
        }
        guard file.version == 1 else {
            throw PluginRegistryError.unsupportedSchemaVersion(file.version)
        }

        let cached = CachedRegistry(
            registryURL: registryURL,
            registry: file,
            etag: http?.value(forHTTPHeaderField: "Etag"),
            lastModified: http?.value(forHTTPHeaderField: "Last-Modified"),
            fetchedAt: Date()
        )
        try writeCachedRegistry(cached)
        return cached
    }

    /// Downloads a plugin's JS bytes from `entry.url`, verifies `sha256`,
    /// returns the bytes on success. Caller is responsible for writing to
    /// the plugins directory.
    static func fetchPluginJS(_ entry: PluginRegistryEntry) async throws -> Data {
        var req = URLRequest(url: entry.url)
        req.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PluginRegistryError.http(status)
        }
        let actual = sha256Hex(data)
        guard actual.caseInsensitiveCompare(entry.sha256) == .orderedSame else {
            throw PluginRegistryError.sha256Mismatch(expected: entry.sha256, actual: actual)
        }
        return data
    }
}

// MARK: - sha256 helpers

nonisolated func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

nonisolated func sha256Hex(_ string: String) -> String {
    sha256Hex(Data(string.utf8))
}
