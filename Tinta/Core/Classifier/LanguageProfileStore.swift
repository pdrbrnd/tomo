import Foundation
import os

nonisolated enum LanguageProfileStore {
    /// Loads all bundled language profile JSON files from `Resources/Profiles/`.
    /// Returns profiles sorted by id. Logs decode failures and missing-bundle issues.
    static func loadBundled() -> [LanguageProfile] {
        let urls = bundleURLs()
        guard !urls.isEmpty else {
            classifierLogger.warning("no profile JSONs found in bundle")
            return []
        }

        let decoder = JSONDecoder()
        var result: [LanguageProfile] = []
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                let profile = try decoder.decode(LanguageProfile.self, from: data)
                result.append(profile)
            } catch {
                classifierLogger.error("failed to load \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        classifierLogger.info("loaded \(result.count) language profiles")
        return result.sorted { $0.id < $1.id }
    }

    private static func bundleURLs() -> [URL] {
        if let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "Profiles"),
           !urls.isEmpty {
            return urls
        }
        if let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil),
           !urls.isEmpty {
            return urls
        }
        // PBXFileSystemSynchronizedRootGroup may copy resources into the bundle
        // without registering them in CFBundle's index. Scan the resource
        // directory directly as a last resort.
        guard let resourceURL = Bundle.main.resourceURL else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(at: resourceURL, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension.lowercased() == "json" }
    }
}
