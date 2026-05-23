import Foundation
import Testing

@testable import Tomo

/// Tests for the on-disk folder-relocate machinery that runs inside
/// `AppState.updateBook`. The bug these were written for: every save
/// produced a phantom `.collision` because URL equality between a directory
/// URL ending in `/` (from `deletingLastPathComponent`) and one without
/// (from `appending(component:)`) disagreed even when both referred to the
/// same on-disk folder. Result: cover changes wouldn't persist, and
/// title/author edits would then orphan the just-written cover.
@Suite("relocateBookFolderIfChanged")
struct FolderRelocateTests {

    // MARK: - .noChange

    @Test
    func noChangeWhenBookIsAlreadyInCanonicalFolder() throws {
        let env = try Env()
        defer { env.cleanup() }

        let bookFolder = try env.makeFolder("Tolkien", "The Hobbit (1937)")
        let fileURL = try env.touch(bookFolder, "tolkien-the-hobbit-1937.epub")
        let book = env.makeBook(
            title: "The Hobbit",
            authors: ["Tolkien"],
            year: 1937,
            fileURL: fileURL
        )

        let result = relocateBookFolderIfChanged(book, libraryRoot: env.root)
        #expect(result.outcome == .noChange)
        // Book and its folder must be untouched.
        #expect(result.book.fileURL == fileURL)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test
    func noChangeWhenFolderURLAndCanonicalDifferOnlyByTrailingSlash() throws {
        // This is the regression case for the original bug. Reconstruct the
        // book's fileURL the same way the index does: from a stored path
        // string via `URL(fileURLWithPath:)`. The two URLs would differ as
        // strings (one trailing slash, one not) but point to the same place.
        let env = try Env()
        defer { env.cleanup() }

        let bookFolder = try env.makeFolder("Asimov", "Foundation (1951)")
        let fileOnDisk = try env.touch(bookFolder, "asimov-foundation-1951.epub")
        let fileURL = URL(fileURLWithPath: fileOnDisk.path)
        let book = env.makeBook(
            title: "Foundation",
            authors: ["Asimov"],
            year: 1951,
            fileURL: fileURL
        )

        let result = relocateBookFolderIfChanged(book, libraryRoot: env.root)
        #expect(result.outcome == .noChange)
    }

    @Test
    func noChangeWhenAuthorContainsAccentedNFDCharacters() throws {
        // macOS APFS often stores filenames in NFD (decomposed). When the
        // current folder URL was reconstructed from disk it can be NFD; the
        // canonical target is freshly composed from the in-memory String
        // which is NFC. Equality on raw path strings would diverge — the
        // fold to NFC keeps both in lockstep.
        let env = try Env()
        defer { env.cleanup() }

        let bookFolder = try env.makeFolder("Brandão", "Crónicas (2020)")
        let fileURL = try env.touch(bookFolder, "brandao-cronicas-2020.epub")
        let book = env.makeBook(
            title: "Crónicas",
            authors: ["Brandão"],
            year: 2020,
            fileURL: fileURL
        )

        let result = relocateBookFolderIfChanged(book, libraryRoot: env.root)
        #expect(result.outcome == .noChange)
    }

    @Test
    func noChangeWhenYearIsNil() throws {
        let env = try Env()
        defer { env.cleanup() }

        let bookFolder = try env.makeFolder("Anonymous", "Sample")
        let fileURL = try env.touch(bookFolder, "anonymous-sample.epub")
        let book = env.makeBook(
            title: "Sample",
            authors: ["Anonymous"],
            year: nil,
            fileURL: fileURL
        )

        let result = relocateBookFolderIfChanged(book, libraryRoot: env.root)
        #expect(result.outcome == .noChange)
    }

    // MARK: - .moved

    @Test
    func movedWhenTitleChanges() throws {
        let env = try Env()
        defer { env.cleanup() }

        let oldFolder = try env.makeFolder("Tolkien", "The Hobit (1937)")
        let fileURL = try env.touch(oldFolder, "tolkien-the-hobit-1937.epub")
        let book = env.makeBook(
            title: "The Hobbit",  // canonical now differs from on-disk folder
            authors: ["Tolkien"],
            year: 1937,
            fileURL: fileURL
        )

        let result = relocateBookFolderIfChanged(book, libraryRoot: env.root)

        if case .moved(let originalFolder) = result.outcome {
            #expect(originalFolder.lastPathComponent == "The Hobit (1937)")
            // The book file moved to the canonical folder, keeping its slug.
            let expected = env.root
                .appending(component: "Tolkien")
                .appending(component: "The Hobbit (1937)")
                .appending(component: "tolkien-the-hobit-1937.epub")
            #expect(
                result.book.fileURL.standardizedFileURL == expected.standardizedFileURL
            )
            #expect(FileManager.default.fileExists(atPath: expected.path))
        } else {
            Issue.record("expected .moved, got \(result.outcome)")
        }
    }

    @Test
    func movedWhenAuthorChanges() throws {
        let env = try Env()
        defer { env.cleanup() }

        let oldFolder = try env.makeFolder("Wrong", "Some Book (2020)")
        let fileURL = try env.touch(oldFolder, "wrong-some-book-2020.epub")
        let book = env.makeBook(
            title: "Some Book",
            authors: ["Correct"],
            year: 2020,
            fileURL: fileURL
        )

        let result = relocateBookFolderIfChanged(book, libraryRoot: env.root)
        guard case .moved = result.outcome else {
            Issue.record("expected .moved, got \(result.outcome)")
            return
        }
        let expectedFolder = env.root
            .appending(component: "Correct")
            .appending(component: "Some Book (2020)")
        #expect(FileManager.default.fileExists(atPath: expectedFolder.path))
    }

    // MARK: - .collision

    @Test
    func collisionWhenTargetFolderAlreadyExists() throws {
        let env = try Env()
        defer { env.cleanup() }

        // Book A is currently parked in a non-canonical folder ("hobit").
        let bookFolder = try env.makeFolder("Tolkien", "The Hobit (1937)")
        let fileURL = try env.touch(bookFolder, "tolkien-the-hobit-1937.epub")

        // Book B already lives at the canonical "The Hobbit (1937)" — the
        // place where A's relocate would land.
        let collidingFolder = try env.makeFolder("Tolkien", "The Hobbit (1937)")
        _ = try env.touch(collidingFolder, "other.epub")

        let book = env.makeBook(
            title: "The Hobbit",
            authors: ["Tolkien"],
            year: 1937,
            fileURL: fileURL
        )

        let result = relocateBookFolderIfChanged(book, libraryRoot: env.root)
        if case .collision(let target) = result.outcome {
            #expect(target.lastPathComponent == "The Hobbit (1937)")
        } else {
            Issue.record("expected .collision, got \(result.outcome)")
        }
        // Original folder still in place — we refused to merge.
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }
}

// MARK: - Test environment

private struct Env {
    let root: URL

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appending(
            component: "tomo-relocate-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeFolder(_ components: String...) throws -> URL {
        var url = root
        for c in components {
            url = url.appending(component: c)
        }
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }

    @discardableResult
    func touch(_ folder: URL, _ filename: String) throws -> URL {
        let url = folder.appending(component: filename)
        try Data().write(to: url)
        return url
    }

    func makeBook(
        title: String,
        authors: [String],
        year: Int?,
        fileURL: URL
    ) -> Book {
        Book(
            id: UUID(),
            title: title,
            authors: authors,
            year: year,
            locale: "und",
            coverPath: nil,
            dateAdded: .now,
            fileURL: fileURL
        )
    }
}
