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
}
