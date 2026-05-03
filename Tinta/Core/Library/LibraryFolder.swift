import Foundation

nonisolated enum LibraryFolder {
    private static let userDefaultsKey = "libraryFolderPath"

    static func load() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: userDefaultsKey) else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func save(_ url: URL?) {
        if let url {
            UserDefaults.standard.set(url.path(percentEncoded: false), forKey: userDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
        }
    }

    /// Walks the library folder and returns each per-book folder that contains
    /// a `metadata.json` sidecar. Expected layout: `<library>/<Author>/<Title (Year)>/`.
    /// Off-main I/O via `Task.detached` internally.
    static func bookFolders(in libraryFolder: URL) async throws -> [URL] {
        try await Task.detached {
            try walkBookFolders(in: libraryFolder)
        }.value
    }

    private static func walkBookFolders(in libraryFolder: URL) throws -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []

        let authorURLs = try fm.contentsOfDirectory(
            at: libraryFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for authorURL in authorURLs where isDirectory(authorURL) {
            let bookURLs = try fm.contentsOfDirectory(
                at: authorURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for bookURL in bookURLs where isDirectory(bookURL) {
                let sidecar = bookURL.appending(component: MetadataSidecar.filename)
                if fm.fileExists(atPath: sidecar.path(percentEncoded: false)) {
                    result.append(bookURL)
                }
            }
        }

        return result
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
