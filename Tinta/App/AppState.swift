import Foundation
import Observation
import os

private nonisolated let logger = Logger(subsystem: "com.pdrbrnd.tinta", category: "library")

@Observable
final class AppState {
    var libraryFolder: URL? {
        didSet { LibraryFolder.save(libraryFolder) }
    }
    let index: BookIndex?
    let importer: LibraryImporter?
    var books: [Book] = []

    init() {
        self.libraryFolder = LibraryFolder.load()
        let openedIndex = BookIndex.open()
        self.index = openedIndex
        self.importer = openedIndex.map { LibraryImporter(index: $0) }
    }

    func loadBooks() async {
        guard let index else { return }
        do {
            self.books = try await index.all()
        } catch {
            logger.error("load books failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func importBook(from url: URL) async {
        guard let importer else {
            logger.error("import called without index/importer")
            return
        }
        guard let libraryFolder else {
            logger.error("import called without library folder")
            return
        }
        do {
            _ = try await importer.importBook(from: url, into: libraryFolder)
            await loadBooks()
        } catch {
            logger.error("import failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
