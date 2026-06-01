import Foundation

/// Loose identity key for duplicate detection: lowercased title + first author,
/// joined by a separator that can't appear in either half by accident.
///
/// Shared by import dedup and plugin-search dedup so both agree on what counts
/// as "the same book". Deliberately coarse — it catches exact / near-exact
/// matches (re-imports, the same title+author under a different year), not
/// fuzzy variants. Genuinely messy metadata (different embedded titles for the
/// same work) will slip through; that's the accepted trade, not a bug.
nonisolated func bookFingerprint(title: String, firstAuthor: String?) -> String {
    "\(title.lowercased())|\(firstAuthor?.lowercased() ?? "")"
}
