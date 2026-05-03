import Foundation
import os

nonisolated enum LibraryFolder {
    private static let userDefaultsKey = "libraryFolderPath"

    /// Returns the persisted library folder URL, or nil if none has been chosen
    /// or the previously chosen folder no longer exists on disk.
    static func load() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: userDefaultsKey) else {
            return nil
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false),
            isDirectory: &isDir
        )
        guard exists, isDir.boolValue else {
            libraryLogger.warning("saved library folder no longer exists: \(path, privacy: .public)")
            return nil
        }
        return url
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

    /// True if the folder contains no non-hidden entries.
    /// Returns false if the folder can't be read (we don't assume empty on error).
    static func isEmpty(_ folder: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return contents.isEmpty
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
