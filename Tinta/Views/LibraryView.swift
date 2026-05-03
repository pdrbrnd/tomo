import SwiftUI

struct LibraryView: View {
    let state: AppState
    @State private var selectedBookID: Book.ID?
    @State private var searchText = ""
    @State private var bookPendingDelete: Book?

    private var filteredBooks: [Book] {
        guard !searchText.isEmpty else { return state.books }
        let needle = searchText.lowercased()
        return state.books.filter { book in
            book.title.lowercased().contains(needle) ||
            book.authors.contains { $0.lowercased().contains(needle) }
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 480)
        .searchable(text: $searchText, prompt: "Search title or author")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await state.rebuildIndex() }
                } label: {
                    Label("Rebuild Index", systemImage: "arrow.clockwise")
                }
                .disabled(state.libraryFolder == nil)
                .help("Wipes the SQLite index and rebuilds it from the metadata.json sidecars on disk")
            }
        }
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
        .confirmationDialog(
            "Move \"\(bookPendingDelete?.title ?? "")\" to Trash?",
            isPresented: Binding(
                get: { bookPendingDelete != nil },
                set: { if !$0 { bookPendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: bookPendingDelete
        ) { book in
            Button("Move to Trash", role: .destructive) {
                Task { await state.deleteBook(book) }
                bookPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                bookPendingDelete = nil
            }
        } message: { _ in
            Text("The book and its metadata will be moved to the Trash. You can restore it from there if needed.")
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        Group {
            if state.books.isEmpty {
                ContentUnavailableView(
                    "No books yet",
                    systemImage: "books.vertical",
                    description: Text("Drop EPUB files anywhere in the window to import.")
                )
            } else if filteredBooks.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List(filteredBooks, selection: $selectedBookID) { book in
                    row(for: book)
                }
            }
        }
        .navigationTitle("Tinta")
        .navigationSplitViewColumnWidth(min: 280, ideal: 340)
    }

    private func row(for book: Book) -> some View {
        HStack(spacing: 8) {
            LocalCoverImage(url: book.coverURL)
                .frame(width: 28, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 2))

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(book.authors.first ?? "Unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let id = book.languageProfileId {
                        Text(id)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
        .contextMenu {
            Button("Move to Trash…", role: .destructive) {
                bookPendingDelete = book
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedBookID, let book = state.books.first(where: { $0.id == id }) {
            BookDetailView(book: book, state: state)
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
