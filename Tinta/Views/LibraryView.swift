import SwiftUI

struct LibraryView: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            bookList
        }
        .frame(minWidth: 520, minHeight: 420)
        .dropDestination(for: URL.self) { urls, _ in
            Task {
                for url in urls where url.pathExtension.lowercased() == "epub" {
                    await state.importBook(from: url)
                }
            }
            return true
        }
        .task { await state.loadBooks() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tinta")
                .font(.largeTitle)

            if let folder = state.libraryFolder {
                Text("Library: \(folder.path(percentEncoded: false))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("No library folder set. Open Settings (⌘,) to choose one.")
                    .foregroundStyle(.secondary)
            }

            Text("Drop EPUB files anywhere in the window to import.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
    }

    @ViewBuilder
    private var bookList: some View {
        if state.books.isEmpty {
            Text("No books yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(state.books) { book in
                Text("\(book.title) — \(book.authors.first ?? "Unknown")")
            }
            .listStyle(.inset)
        }
    }
}
