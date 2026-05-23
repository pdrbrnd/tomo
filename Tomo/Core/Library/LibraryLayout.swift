import Foundation

/// Computes the canonical on-disk layout for the library:
///   `<library>/<Author>/<Title (Year)>/`
///
/// One source of truth so the importer (creating folders) and `AppState`
/// (relocating folders on edit) can't drift.
enum LibraryLayout {
    /// Canonical folder for the given title / first author / year. Returns
    /// `<library>/<sanitizedAuthor>/<sanitizedTitle> (year)/`. When `year`
    /// is nil, the year suffix is omitted: `<library>/<author>/<title>/`.
    nonisolated static func bookFolderURL(
        in libraryFolder: URL,
        title: String,
        firstAuthor: String?,
        year: Int?
    ) -> URL {
        let author = sanitizePathComponent(firstAuthor ?? "Unknown")
        let titlePart = sanitizePathComponent(title)
        let folderName = year.map { "\(titlePart) (\($0))" } ?? titlePart
        return
            libraryFolder
            .appending(component: author)
            .appending(component: folderName)
    }

    /// Strips characters that aren't safe on macOS / iCloud / FAT filesystems.
    /// Replaces them with "-" and trims surrounding whitespace.
    nonisolated static func sanitizePathComponent(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?*\"<>|")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
