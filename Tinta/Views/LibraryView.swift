import SwiftUI

struct LibraryView: View {
    let state: AppState
    @State private var selectedBookID: Book.ID?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 480)
        .dropDestination(for: URL.self) { urls, _ in
            let epubs = urls.filter { $0.pathExtension.lowercased() == "epub" }
            guard !epubs.isEmpty else { return false }
            Task {
                for url in epubs {
                    await state.importBook(from: url)
                }
            }
            return true
        }
        .task { await state.loadBooks() }
    }

    @ViewBuilder
    private var sidebar: some View {
        if state.books.isEmpty {
            ContentUnavailableView(
                "No books yet",
                systemImage: "books.vertical",
                description: Text("Drop EPUB files anywhere in the window to import.")
            )
            .navigationTitle("Tinta")
        } else {
            List(state.books, selection: $selectedBookID) { book in
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .lineLimit(1)
                    Text(book.authors.first ?? "Unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .tag(book.id)
            }
            .navigationTitle("Tinta")
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedBookID, let book = state.books.first(where: { $0.id == id }) {
            BookDetailView(book: book)
        } else if state.libraryFolder == nil {
            ContentUnavailableView(
                "No library folder",
                systemImage: "folder.badge.questionmark",
                description: Text("Open Settings (⌘,) to choose a folder.")
            )
        } else {
            ContentUnavailableView(
                "Select a book",
                systemImage: "book"
            )
        }
    }
}
