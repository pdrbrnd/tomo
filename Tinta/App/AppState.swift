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

    private func openIndexIfNeeded() async {
        guard index == nil else { return }
        let opened = await Task.detached { BookIndex.open() }.value
        self.index = opened
        self.importer = opened.map { LibraryImporter(index: $0) }
    }
}
