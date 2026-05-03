import SwiftUI

struct LibraryView: View {
    let state: AppState
    @State private var selectedBookID: Book.ID?
    @State private var searchText = ""
    @State private var bookPendingDelete: Book?
    @State private var deviceDropTargeted = false

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
        VStack(spacing: 0) {
            sidebarContent
            if let device = state.device {
                deviceFooter(device: device)
            }
        }
        .navigationTitle("Acervo")
        .navigationSplitViewColumnWidth(min: 280, ideal: 340)
    }

    @ViewBuilder
    private var sidebarContent: some View {
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
                    if book.locale != "und" {
                        Text(book.locale)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
        .opacity(rowOpacity(for: book))
        .draggable(book.fileURL)
        .contextMenu {
            Button("Move to Trash…", role: .destructive) {
                bookPendingDelete = book
            }
            if let device = state.device, isOnDevice(book) {
                Divider()
                Button("Remove from \(device.displayName)", role: .destructive) {
                    Task { await state.removeFromDevice(book: book) }
                }
            }
        }
    }

    private func deviceFooter(device: any BookDevice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "ipad.and.iphone")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.displayName)
                        .font(.callout)
                    Text(deviceFooterSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await state.ejectDevice() }
                } label: {
                    Image(systemName: "eject.fill")
                }
                .buttonStyle(.borderless)
                .help("Eject \(device.displayName). Books appear on the device after eject.")
            }

            if let warning = device.compatibilityWarning {
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(deviceDropTargeted ? Color.accentColor.opacity(0.18) : Color.clear)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(.separator),
            alignment: .top
        )
        .background(.bar)
        .dropDestination(for: URL.self) { urls, _ in
            let booksToSend = urls
                .compactMap { url in state.books.first(where: { $0.fileURL == url }) }
                .filter { device.canAccept($0) }
            guard !booksToSend.isEmpty else { return false }
            Task {
                for book in booksToSend {
                    await state.sendToDevice(book: book)
                }
            }
            return true
        } isTargeted: { targeted in
            deviceDropTargeted = targeted
        }
    }

    private var deviceFooterSubtitle: String {
        if deviceDropTargeted { return "Drop to send" }
        let count = state.deviceFilenames.count
        return "\(count) book\(count == 1 ? "" : "s") on device"
    }

    private func rowOpacity(for book: Book) -> Double {
        guard state.device != nil else { return 1.0 }
        return isOnDevice(book) ? 1.0 : 0.45
    }

    private func isOnDevice(_ book: Book) -> Bool {
        guard let device = state.device else { return false }
        return state.deviceFilenames.contains(device.deviceFilename(for: book))
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
