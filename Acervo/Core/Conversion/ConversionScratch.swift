import Foundation
import os

/// Owns the on-disk scratch directory used during a single conversion.
/// Path: `~/Library/Application Support/com.pdrbrnd.acervo/ConversionCache/<uuid>/`.
/// Application Support is not iCloud-synced, so converted bytes never leak
/// back into the user's library or sync chain. The directory is deleted at
/// the end of the body closure (success or failure) — converted output is
/// transient by design; the EPUB on disk is the canonical artefact.
nonisolated enum ConversionScratch {
    static func withScratchDirectory<T: Sendable>(
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let dir = try makeScratchDirectory()
        do {
            let result = try await body(dir)
            cleanup(dir)
            return result
        } catch {
            cleanup(dir)
            throw error
        }
    }

    private static func makeScratchDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let cacheRoot = appSupport
            .appendingPathComponent("com.pdrbrnd.acervo", isDirectory: true)
            .appendingPathComponent("ConversionCache", isDirectory: true)
        let scratch = cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return scratch
    }

    private static func cleanup(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            conversionLogger.warning(
                "scratch cleanup failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
