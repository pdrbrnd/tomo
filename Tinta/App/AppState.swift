import Foundation
import Observation
import os

@Observable
final class AppState {
    var libraryFolder: URL? {
        didSet { LibraryFolder.save(libraryFolder) }
    }
    private(set) var index: BookIndex?
    private(set) var importer: LibraryImporter?
    var books: [Book] = []

    init() {
        self.libraryFolder = LibraryFolder.load()
    }

    func loadBooks() async {
        await openIndexIfNeeded()
        guard let index else { return }
        do {
            self.books = try await index.all()
        } catch {
            libraryLogger.error("load books failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func importBook(from url: URL) async {
        await openIndexIfNeeded()
        guard let importer else {
            libraryLogger.error("import called without index/importer")
            return
        }
        guard let libraryFolder else {
            libraryLogger.error("import called without library folder")
            return
        }
        do {
            _ = try await importer.importBook(from: url, into: libraryFolder)
            await loadBooks()
        } catch {
            libraryLogger.error("import failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func deleteBook(_ book: Book) async {
        await openIndexIfNeeded()
        guard let index else {
            libraryLogger.error("delete: no index")
            return
        }
        let bookFolder = book.fileURL.deletingLastPathComponent()
        do {
            try await Task.detached {
                try FileManager.default.trashItem(at: bookFolder, resultingItemURL: nil)
            }.value
            try await index.delete(book)
            await loadBooks()
            libraryLogger.info("trashed: \(book.title, privacy: .public)")
        } catch {
            libraryLogger.error("delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func rebuildIndex() async {
        await openIndexIfNeeded()
        guard let index else {
            libraryLogger.error("rebuild: no index")
            return
        }
        guard let libraryFolder else {
            libraryLogger.error("rebuild: no library folder")
            return
        }
        do {
            try await index.wipeAll()
            let folders = try await LibraryFolder.bookFolders(in: libraryFolder)
            var imported = 0
            for folder in folders {
                do {
                    let book = try MetadataSidecar.read(from: folder)
                    try await index.add(book)
                    imported += 1
                } catch {
                    libraryLogger.error("rebuild: skipped \(folder.path(percentEncoded: false), privacy: .public) - \(error.localizedDescription, privacy: .public)")
                }
            }
            libraryLogger.info("rebuild: indexed \(imported) of \(folders.count) folders")
            await loadBooks()
        } catch {
            libraryLogger.error("rebuild failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func openIndexIfNeeded() async {
        guard index == nil else { return }
        let opened = await Task.detached { BookIndex.open() }.value
        self.index = opened
        self.importer = opened.map { LibraryImporter(index: $0) }
    }
}
