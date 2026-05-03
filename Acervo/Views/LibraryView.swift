import SwiftUI
import AppKit
import PhosphorSwift

struct LibraryView: View {
    let state: AppState

    @State private var selectedBookID: Book.ID?
    @State private var inspectorOpen = false
    @State private var searchText = ""
    @State private var languageFilter: String?
    @State private var bookPendingDelete: Book?
    @State private var editingBook: Book?
    @State private var dropTargeted = false
    @FocusState private var searchFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let inspectorWidth: CGFloat = 332
    private static let inspectorInset: CGFloat = 8
    private static let inspectorPaneWidth: CGFloat = inspectorWidth + inspectorInset * 2

    private var filteredBooks: [Book] {
        let bySearch: [Book]
        if searchText.isEmpty {
            bySearch = state.books
        } else {
            let needle = searchText.lowercased()
            bySearch = state.books.filter { book in
                book.title.lowercased().contains(needle) ||
                book.authors.contains { $0.lowercased().contains(needle) }
            }
        }
        guard let lang = languageFilter else { return bySearch }
        return bySearch.filter { $0.locale == lang }
    }

    private var selectedBook: Book? {
        guard let id = selectedBookID else { return nil }
        return state.books.first(where: { $0.id == id })
    }

    private var languageCounts: [String: Int] {
        Dictionary(grouping: state.books, by: { $0.locale }).mapValues(\.count)
    }

    /// Resolves the current device into something the inspector can render
    /// without knowing about `BookDevice` or `AppState`.
    private func deviceContext(for book: Book) -> BookInspector.DeviceContext? {
        guard let device = state.device else { return nil }
        return BookInspector.DeviceContext(
            displayName: device.displayName,
            isOnDevice: state.deviceFilenames.contains(device.deviceFilename(for: book)),
            canSend: device.canAccept(book)
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            mainPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if inspectorOpen {
                inspectorPane
                    .frame(width: Self.inspectorPaneWidth)
                    .transition(inspectorTransition)
            }
        }
        .ignoresSafeArea(.all)
        .background(WindowCustomizer(cornerRadius: Theme.Radius.window))
        .frame(minWidth: 880, minHeight: 600)
        .animation(inspectorAnimation, value: inspectorOpen)
        .task { await state.loadBooks() }
        .sheet(item: $editingBook) { book in
            EditBookView(book: book, state: state) { updated in
                Task { await state.updateBook(updated) }
            }
        }
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
            Text("The book and its metadata will be moved to the Trash.")
        }
    }

    // MARK: - Main pane

    private var mainPane: some View {
        ZStack(alignment: .top) {
            Theme.canvas
                .ignoresSafeArea()

            gridArea
                .ignoresSafeArea(.all, edges: .top)

            TopChrome(
                searchText: $searchText,
                searchFocused: $searchFocused,
                isFilterActive: languageFilter != nil
            ) {
                LanguageFilterPopover(
                    counts: languageCounts,
                    total: state.books.count,
                    selected: $languageFilter,
                    onSelect: {}
                )
            }

            if let device = state.device {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        DeviceTile(
                            displayName: device.displayName,
                            bookCount: state.deviceFilenames.count,
                            onEject: { Task { await state.ejectDevice() } },
                            onDrop: { urls in
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
                            }
                        )
                        .padding(.trailing, Theme.Spacing.lg)
                        .padding(.bottom, Theme.Spacing.lg)
                    }
                }
            }

            if dropTargeted {
                DropOverlay()
                    .ignoresSafeArea(.all)
                    .transition(.opacity)
            }

            keyboardShortcuts
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
        } isTargeted: { targeted in
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.20)) {
                dropTargeted = targeted
            }
        }
    }

    // MARK: - Grid

    @ViewBuilder
    private var gridArea: some View {
        if state.libraryFolder == nil {
            placeholderText("Open Settings (⌘,) to choose a library folder.")
        } else if state.books.isEmpty {
            placeholderText("Drop a book to begin.")
        } else if filteredBooks.isEmpty {
            placeholderText("Nothing matches “\(searchText)”.")
        } else {
            grid
        }
    }

    private var grid: some View {
        GeometryReader { proxy in
            let margin: CGFloat = Theme.Spacing.xxl
            let gutter: CGFloat = Theme.Spacing.xxl
            let minCardWidth: CGFloat = 168
            let maxCardWidth: CGFloat = 224
            let topClearance: CGFloat = Theme.Spacing.xxl

            let availableWidth = proxy.size.width - 2 * margin
            let cols = max(1, Int((availableWidth + gutter) / (minCardWidth + gutter)))
            let computed = (availableWidth - CGFloat(cols - 1) * gutter) / CGFloat(cols)
            let cardWidth = min(maxCardWidth, max(minCardWidth, computed))

            ScrollView {
                ZStack(alignment: .top) {
                    // Tap target for empty-grid clicks. Inside the scroll
                    // content so it actually receives clicks (ScrollView
                    // would otherwise eat them via its own gesture handling).
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.32, bounce: 0.10)) {
                                selectedBookID = nil
                                searchFocused = false
                            }
                        }

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: gutter), count: cols),
                        alignment: .center,
                        spacing: gutter
                    ) {
                        ForEach(filteredBooks) { book in
                            bookCell(book, cardWidth: cardWidth)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, margin)
                    .padding(.top, topClearance + margin)
                    .padding(.bottom, margin)
                }
                .frame(minHeight: proxy.size.height)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func bookCell(_ book: Book, cardWidth: CGFloat) -> some View {
        BookCard(
            book: book,
            isSelected: book.id == selectedBookID,
            cardWidth: cardWidth,
            menu: { bookMenu(book) }
        )
        .draggable(book.fileURL)
        // simultaneousGesture so single-tap fires immediately, no double-tap
        // disambiguation lag. Double-click also fires simultaneously: the
        // single-tap selects (idempotent), then the double-tap opens. The
        // selection is harmless side effect; the user sees the book open.
        .simultaneousGesture(TapGesture(count: 1).onEnded {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.32, bounce: 0.10)) {
                selectedBookID = book.id
                searchFocused = false
            }
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            NSWorkspace.shared.open(book.fileURL)
        })
        .contextMenu { bookMenu(book) }
    }

    @ViewBuilder
    private func bookMenu(_ book: Book) -> some View {
        bookMenuItem("Show Details", icon: .info) {
            selectedBookID = book.id
            inspectorOpen = true
        }
        bookMenuItem("Open in Default App", icon: .arrowSquareOut) {
            NSWorkspace.shared.open(book.fileURL)
        }
        bookMenuItem("Edit…", icon: .pencilSimple) {
            editingBook = book
        }
        bookMenuItem("Show in Finder", icon: .folderOpen) {
            NSWorkspace.shared.activateFileViewerSelecting([book.fileURL])
        }
        if let device = state.device, device.canAccept(book) {
            MenuDivider()
            if isOnDevice(book) {
                bookMenuItem("Remove from \(device.displayName)", icon: .deviceTablet, destructive: true) {
                    Task { await state.removeFromDevice(book: book) }
                }
            } else {
                bookMenuItem("Send to \(device.displayName)", icon: .deviceTablet) {
                    Task { await state.sendToDevice(book: book) }
                }
            }
        }
        MenuDivider()
        bookMenuItem("Move to Trash…", icon: .trash, destructive: true) {
            bookPendingDelete = book
        }
    }

    private func bookMenuItem(
        _ title: String,
        icon: Ph,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            HStack(spacing: 9) {
                Icon(symbol: icon, weight: .regular, size: 13)
                    .frame(width: 14)
                Text(title)
            }
        }
    }

    private func placeholderText(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.primary.opacity(0.45))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Inspector

    private var inspectorPane: some View {
        BookInspector(
            book: selectedBook,
            device: selectedBook.flatMap { deviceContext(for: $0) },
            onClose: { inspectorOpen = false },
            onEdit: { if let book = selectedBook { editingBook = book } },
            onShowInFinder: {
                if let book = selectedBook {
                    NSWorkspace.shared.activateFileViewerSelecting([book.fileURL])
                }
            },
            onSendToDevice: {
                if let book = selectedBook {
                    Task { await state.sendToDevice(book: book) }
                }
            },
            onRequestDelete: { if let book = selectedBook { bookPendingDelete = book } }
        )
        .frame(width: Self.inspectorWidth)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 0.5)
        )
        .softShadow(elevated: true)
        .padding(Self.inspectorInset)
    }

    private var inspectorTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .move(edge: .trailing).combined(with: .opacity)
    }

    private var inspectorAnimation: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.18)
        }
        return .smooth(duration: 0.32, extraBounce: 0.10)
    }

    private func isOnDevice(_ book: Book) -> Bool {
        guard let device = state.device else { return false }
        return state.deviceFilenames.contains(device.deviceFilename(for: book))
    }

    // MARK: - Keyboard shortcuts

    private var keyboardShortcuts: some View {
        ZStack {
            Button("") { inspectorOpen.toggle() }
                .keyboardShortcut("i", modifiers: .command)
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("") {
                if let book = selectedBook {
                    NSWorkspace.shared.open(book.fileURL)
                }
            }
            .keyboardShortcut("o", modifiers: .command)
            Button("") { handleEscape() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func handleEscape() {
        if searchFocused { searchFocused = false; return }
        if !searchText.isEmpty { searchText = ""; return }
        if selectedBookID != nil { selectedBookID = nil; return }
        if inspectorOpen { inspectorOpen = false }
    }
}
