import Foundation

enum CoordinatedReadError: LocalizedError {
    case downloadTimedOut

    var errorDescription: String? {
        switch self {
        case .downloadTimedOut:
            "This book is still downloading from iCloud. Try again in a moment."
        }
    }
}

/// Makes an iCloud-backed file available locally before we read its bytes.
///
/// The library folder may live in iCloud Drive (Principle 3), where files
/// get evicted to `.icloud` placeholders to save space. Opening an evicted
/// file's contents fails or returns nothing. This triggers the download and
/// waits for it to land. A cheap no-op for ordinary local files — the common
/// case — so it's safe to call before every content read.
enum CoordinatedRead {
    /// Ensures `url` is downloaded before the caller reads it. Returns
    /// immediately for local (non-ubiquitous) files and for iCloud files
    /// that are already present. Throws `CoordinatedReadError.downloadTimedOut`
    /// if an evicted file doesn't finish downloading within `timeout`.
    static func ensureDownloaded(_ url: URL, timeout: Duration = .seconds(60)) async throws {
        guard needsDownload(url) else { return }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if !needsDownload(url) { return }
            try await Task.sleep(for: .milliseconds(150))
        }
        if needsDownload(url) { throw CoordinatedReadError.downloadTimedOut }
    }

    /// True only for an iCloud item that isn't downloaded yet. A local file,
    /// or an iCloud file already present, returns false.
    private static func needsDownload(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
            values.isUbiquitousItem == true,
            let status = values.ubiquitousItemDownloadingStatus
        else { return false }
        return status == .notDownloaded
    }
}
