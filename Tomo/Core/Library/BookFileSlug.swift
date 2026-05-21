import Foundation

/// Builds a kebab-case ASCII filename for a book: `<author>-<title>[-<year>].<ext>`.
/// Non-Latin scripts are transliterated, diacritics stripped, anything that
/// isn't `[a-z0-9]` becomes a hyphen. Identity lives in the filename so
/// devices (Kindle in particular) don't collide every book at `book.epub`.
///
/// Pure / nonisolated; the `id` is only used as a last-resort uniqueness
/// fallback when both title and author degrade to empty.
nonisolated func bookFileSlug(
    title: String,
    author: String?,
    year: Int?,
    ext: String,
    id: UUID
) -> String {
    let extLower = ext.lowercased()
    let authorSlug = slugify(author ?? "") ?? "unknown"
    let titleSlug = slugify(title) ?? "untitled"
    var stem = "\(authorSlug)-\(titleSlug)"
    if let year { stem += "-\(year)" }

    // Both author and title degraded to defaults and there's no year —
    // fall back to id prefix so the filename still uniquely identifies
    // the book.
    if authorSlug == "unknown", titleSlug == "untitled", year == nil {
        stem = "untitled-\(id.uuidString.prefix(8).lowercased())"
    }

    // Cap total filename at 200 chars to stay well under the FAT32 255-byte
    // ceiling. Filenames are ASCII so char count == byte count.
    let maxStem = 200 - extLower.count - 1
    if stem.count > maxStem {
        stem = String(stem.prefix(maxStem))
        while stem.last == "-" { stem.removeLast() }
    }

    return "\(stem).\(extLower)"
}

/// Transliterates to Latin, strips diacritics, lowercases, collapses any
/// non-`[a-z0-9]` run into a single hyphen, trims hyphens at the edges.
/// Returns nil when nothing survives.
private nonisolated func slugify(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let latin = trimmed.applyingTransform(.toLatin, reverse: false) ?? trimmed
    let ascii = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
    let lower = ascii.lowercased()

    var result = ""
    var lastWasHyphen = true  // suppresses leading hyphen
    for char in lower {
        if char.isASCII, char.isLetter || char.isNumber {
            result.append(char)
            lastWasHyphen = false
        } else if !lastWasHyphen {
            result.append("-")
            lastWasHyphen = true
        }
    }
    while result.last == "-" { result.removeLast() }
    return result.isEmpty ? nil : result
}
