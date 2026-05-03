import Foundation
import Observation

@Observable
final class AppState {
    var libraryFolder: URL? {
        didSet { LibraryFolder.save(libraryFolder) }
    }
    let index: BookIndex?

    init() {
        self.libraryFolder = LibraryFolder.load()
        self.index = BookIndex.open()
    }
}
