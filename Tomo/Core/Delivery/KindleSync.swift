import Foundation

/// Reconciliation tasks that run when a Kindle volume mounts. Today this is
/// just cover-thumbnail restoration — Amazon's home-screen scanner overwrites
/// our covers with a "no image available" placeholder whenever the device
/// goes online, so we resurrect them every time the Kindle reappears on USB.
///
/// Future device-side fixes plug in here as additional best-effort calls.
/// No protocol / no registry on purpose: each fix has different risk
/// profile and idempotency rules; forcing a shared interface would
/// hide those differences.
nonisolated enum KindleSync {
    static func run(volumeURL: URL) async {
        await Task.detached {
            KindleCoverThumbnail.restoreOverwrittenThumbnails(volumeURL: volumeURL)
        }.value
    }
}
