import SwiftUI
import AppKit
import PhosphorSwift

struct LibraryView: View {
    let state: AppState

    @State private var selectedBookIDs: Set<Book.ID> = []
    @State private var selectionAnchor: Book.ID?
    @State private var inspectorOpen = false
    @State private var searchText = ""
    @State private var languageFilter: String?
    @State private var booksPendingDelete: [Book] = []
    @State private var editingBook: Book?
    @State private var externalDropTargeted = false
    @State private var marquee: MarqueeState = .inactive
    @State private var cardFrames: [Book.ID: CGRect] = [:]
    @State private var contextMenuBookID: Book.ID?
    @State private var dragEndPollingTask: Task<Void, Never>?
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

    /// The book shown in the inspector. Only resolves when exactly one is
    /// selected — multi-select shows a count placeholder instead.
    private var inspectorBook: Book? {
        guard selectedBookIDs.count == 1, let id = selectedBookIDs.first else { return nil }
        return state.books.first(where: { $0.id == id })
    }

    /// Selected books in the order they appear in the current filtered grid.
    private var selectedBooksInOrder: [Book] {
        filteredBooks.filter { selectedBookIDs.contains($0.id) }
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
            deleteDialogTitle,
            isPresented: Binding(
                get: { !booksPendingDelete.isEmpty },
                set: { if !$0 { booksPendingDelete = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                let toDelete = booksPendingDelete
                Task {
                    await state.deleteBooks(toDelete)
                }
                selectedBookIDs.subtract(toDelete.map(\.id))
                if let anchor = selectionAnchor, toDelete.contains(where: { $0.id == anchor }) {
                    selectionAnchor = nil
                }
                booksPendingDelete = []
            }
            Button("Cancel", role: .cancel) {
                booksPendingDelete = []
            }
        } message: {
            Text(booksPendingDelete.count == 1
                ? "The book and its metadata will be moved to the Trash."
                : "These books and their metadata will be moved to the Trash."
            )
        }
    }

    private var deleteDialogTitle: String {
        if booksPendingDelete.count == 1 {
            return "Move \"\(booksPendingDelete[0].title)\" to Trash?"
        }
        return "Move \(booksPendingDelete.count) books to Trash?"
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
                            inAppDragCount: state.inAppDragCount,
                            sendState: state.deviceSendState,
                            onEject: { Task { await state.ejectDevice() } },
                            onDrop: { drag in
                                let books = drag.bookIDs
                                    .compactMap { id in state.books.first(where: { $0.id == id }) }
                                guard !books.isEmpty else { return false }
                                Task { await state.sendBooksToDevice(books) }
                                return true
                            }
                        )
                        .padding(.trailing, Theme.Spacing.lg)
                        .padding(.bottom, Theme.Spacing.lg)
                    }
                }
            }

            if externalDropTargeted {
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
                externalDropTargeted = targeted
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
                ZStack(alignment: .topLeading) {
                    // Empty-space gesture host: tap clears selection;
                    // drag starts marquee. Cards layer above this and
                    // intercept their own gestures, so a press on a card
                    // never triggers the marquee.
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(marqueeGesture)
                        .onTapGesture {
                            clearSelection()
                            searchFocused = false
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

                    if let rect = marquee.rect {
                        SelectionRectangle()
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: proxy.size.height)
                .coordinateSpace(name: Self.gridCoordinateSpace)
                .onPreferenceChange(CardFramePreference.self) { frames in
                    cardFrames = frames
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private static let gridCoordinateSpace = "library.grid"

    private func bookCell(_ book: Book, cardWidth: CGFloat) -> some View {
        let isSelected = selectedBookIDs.contains(book.id)
        return BookCard(
            book: book,
            isSelected: isSelected,
            cardWidth: cardWidth,
            menu: { dismiss in bookMenu(for: book, dismiss: dismiss) }
        )
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: CardFramePreference.self,
                    value: [book.id: geo.frame(in: .named(Self.gridCoordinateSpace))]
                )
            }
        )
        // Pure Transferable both sides: .draggable + .dropDestination match
        // through SwiftUI's Transferable plumbing. Earlier we used .onDrag
        // (raw NSItemProvider) and the dropDestination's `isTargeted` never
        // fired — UTType conformance lookups don't work for unregistered UTIs,
        // and the bridging across APIs went through the same layer. Both
        // now go through .draggable, and the UTI is declared in Info.plist.
        //
        // Side effects (selection sync + drag-state broadcast) live in the
        // payload autoclosure. SwiftUI invokes it when constructing the drag,
        // which is at drag start. Matches what we want.
        .draggable(buildBookDrag(for: book)) {
            BookDragPreview(books: dragBooks(for: book))
        }
        // simultaneousGesture so single-tap fires immediately, no double-tap
        // disambiguation lag. Modifier flags read from NSEvent because
        // TapGesture.modifiers() doesn't reliably exclude plain taps when
        // both forms are attached simultaneously.
        .simultaneousGesture(TapGesture(count: 1).onEnded {
            let flags = NSEvent.modifierFlags
            if flags.contains(.command) {
                handleCommandClick(book)
            } else if flags.contains(.shift) {
                handleShiftClick(book)
            } else {
                handlePlainClick(book)
            }
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            NSWorkspace.shared.open(book.fileURL)
        })
        .overlay(
            RightClickCatcher {
                // Standard macOS behavior: right-clicking an unselected
                // item should select it before showing the menu.
                if !selectedBookIDs.contains(book.id) {
                    selectedBookIDs = [book.id]
                    selectionAnchor = book.id
                }
                contextMenuBookID = book.id
            }
        )
        .popover(
            isPresented: Binding(
                get: { contextMenuBookID == book.id },
                set: { if !$0 { contextMenuBookID = nil } }
            ),
            arrowEdge: .top
        ) {
            VStack(alignment: .leading, spacing: 0) {
                bookMenu(for: book) { contextMenuBookID = nil }
            }
            .menuPopoverContainer()
        }
    }

    /// Builds the BookDrag payload AND fires the drag-start side effects
    /// (selection sync, broadcast count, start drag-end polling). SwiftUI
    /// invokes this when constructing the drag operation, so the side
    /// effects fire at drag start — not on every body evaluation.
    private func buildBookDrag(for book: Book) -> BookDrag {
        let books = dragBooks(for: book)
        // Mirror Finder: starting a drag on an unselected card selects it.
        if !selectedBookIDs.contains(book.id) {
            selectedBookIDs = [book.id]
            selectionAnchor = book.id
        }
        state.inAppDragCount = books.count
        startDragEndPolling()
        return BookDrag(bookIDs: books.map(\.id))
    }

    /// Polls the mouse-button state to detect when the user releases the
    /// drag. NSEvent local monitors don't deliver `.leftMouseUp` events
    /// while a drag operation is active — the system's NSDragging machinery
    /// consumes them. Polling `NSEvent.pressedMouseButtons` works because
    /// it reads the live HID state, independent of event delivery.
    ///
    /// Cancel-and-replace: a fast double-drag (drop, then immediately drag
    /// again before the previous task observes the release) would otherwise
    /// have two tasks racing — the older one would see `pressedMouseButtons == 0`
    /// during the brief gap and clear the new drag's count.
    private func startDragEndPolling() {
        dragEndPollingTask?.cancel()
        dragEndPollingTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            while !Task.isCancelled, NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled else { return }
            state.inAppDragCount = 0
        }
    }

    // MARK: - Selection handling

    private func handlePlainClick(_ book: Book) {
        withAnimation(selectionAnimation) {
            selectedBookIDs = [book.id]
            selectionAnchor = book.id
            searchFocused = false
        }
    }

    private func handleCommandClick(_ book: Book) {
        withAnimation(selectionAnimation) {
            if selectedBookIDs.contains(book.id) {
                selectedBookIDs.remove(book.id)
                if selectionAnchor == book.id { selectionAnchor = nil }
            } else {
                selectedBookIDs.insert(book.id)
                selectionAnchor = book.id
            }
            searchFocused = false
        }
    }

    private func handleShiftClick(_ book: Book) {
        let books = filteredBooks
        guard let toIndex = books.firstIndex(where: { $0.id == book.id }) else { return }
        let anchor = selectionAnchor ?? selectedBookIDs.first
        guard let anchor, let fromIndex = books.firstIndex(where: { $0.id == anchor }) else {
            handlePlainClick(book)
            return
        }
        let lower = min(fromIndex, toIndex)
        let upper = max(fromIndex, toIndex)
        withAnimation(selectionAnimation) {
            selectedBookIDs = Set(books[lower...upper].map(\.id))
            // Keep anchor stable so subsequent shift+clicks pivot from
            // the same starting point — matches Finder.
            searchFocused = false
        }
    }

    private func clearSelection() {
        withAnimation(selectionAnimation) {
            selectedBookIDs.removeAll()
            selectionAnchor = nil
        }
    }

    private var selectionAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.32, bounce: 0.10)
    }

    // MARK: - Drag

    /// Books carried by a drag starting on `book`. Pure: side effects
    /// (selection sync, drag-count broadcast) live in the drag preview's
    /// `.onAppear`/`.onDisappear`.
    private func dragBooks(for book: Book) -> [Book] {
        if selectedBookIDs.contains(book.id) {
            return selectedBooksInOrder
        }
        return [book]
    }

    // MARK: - Marquee

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.gridCoordinateSpace))
            .onChanged { value in
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                marquee = .active(rect: rect)
                let hitIDs = Set(
                    cardFrames
                        .filter { _, frame in frame.intersects(rect) }
                        .keys
                )
                selectedBookIDs = hitIDs
                // Anchor in grid order, not Set iteration order, so a
                // subsequent shift+click pivots from a stable point.
                selectionAnchor = filteredBooks.first(where: { hitIDs.contains($0.id) })?.id
            }
            .onEnded { _ in
                marquee = .inactive
            }
    }

    /// Context menu for `book`. When the right-clicked book is part of a
    /// multi-selection, surface bulk actions on the whole selection;
    /// otherwise show the single-book menu. `dismiss` is called after
    /// any selected item action so the popover closes.
    @ViewBuilder
    private func bookMenu(for book: Book, dismiss: @escaping () -> Void = {}) -> some View {
        if selectedBookIDs.count > 1, selectedBookIDs.contains(book.id) {
            bulkMenu(for: selectedBooksInOrder, dismiss: dismiss)
        } else {
            singleMenu(for: book, dismiss: dismiss)
        }
    }

    @ViewBuilder
    private func singleMenu(for book: Book, dismiss: @escaping () -> Void) -> some View {
        bookMenuItem("Show Details", icon: .info) {
            selectedBookIDs = [book.id]
            selectionAnchor = book.id
            inspectorOpen = true
            dismiss()
        }
        bookMenuItem("Open in Default App", icon: .arrowSquareOut) {
            NSWorkspace.shared.open(book.fileURL)
            dismiss()
        }
        bookMenuItem("Edit…", icon: .pencilSimple) {
            editingBook = book
            dismiss()
        }
        bookMenuItem("Show in Finder", icon: .folderOpen) {
            NSWorkspace.shared.activateFileViewerSelecting([book.fileURL])
            dismiss()
        }
        if let device = state.device, device.canAccept(book) {
            MenuDivider()
            if isOnDevice(book) {
                bookMenuItem("Remove from \(device.displayName)", icon: .deviceTablet, destructive: true) {
                    Task { await state.removeFromDevice(book: book) }
                    dismiss()
                }
            } else {
                bookMenuItem("Send to \(device.displayName)", icon: .deviceTablet) {
                    Task { await state.sendToDevice(book: book) }
                    dismiss()
                }
            }
        }
        MenuDivider()
        bookMenuItem("Move to Trash…", icon: .trash, destructive: true) {
            booksPendingDelete = [book]
            dismiss()
        }
    }

    @ViewBuilder
    private func bulkMenu(for books: [Book], dismiss: @escaping () -> Void) -> some View {
        if let device = state.device {
            let sendable = books.filter { device.canAccept($0) }
            if !sendable.isEmpty {
                bookMenuItem("Send \(sendable.count) to \(device.displayName)", icon: .deviceTablet) {
                    Task { await state.sendBooksToDevice(sendable) }
                    dismiss()
                }
                MenuDivider()
            }
        }
        bookMenuItem("Move \(books.count) to Trash…", icon: .trash, destructive: true) {
            booksPendingDelete = books
            dismiss()
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
            book: inspectorBook,
            device: inspectorBook.flatMap { deviceContext(for: $0) },
            multiSelectionCount: selectedBookIDs.count > 1 ? selectedBookIDs.count : nil,
            onClose: { inspectorOpen = false },
            onEdit: { if let book = inspectorBook { editingBook = book } },
            onShowInFinder: {
                if let book = inspectorBook {
                    NSWorkspace.shared.activateFileViewerSelecting([book.fileURL])
                }
            },
            onSendToDevice: {
                if let book = inspectorBook {
                    Task { await state.sendToDevice(book: book) }
                }
            },
            onRequestDelete: { if let book = inspectorBook { booksPendingDelete = [book] } }
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
            Button("") { handleSelectAll() }
                .keyboardShortcut("a", modifiers: .command)
            Button("") {
                if let book = inspectorBook {
                    NSWorkspace.shared.open(book.fileURL)
                }
            }
            .keyboardShortcut("o", modifiers: .command)
            Button("") { handleDeleteShortcut() }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("") { handleEscape() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func handleSelectAll() {
        guard !searchFocused else { return }
        withAnimation(selectionAnimation) {
            selectedBookIDs = Set(filteredBooks.map(\.id))
            selectionAnchor = filteredBooks.first?.id
        }
    }

    private func handleDeleteShortcut() {
        // Don't hijack ⌘⌫ when the search field is focused — that's a
        // text-editing shortcut.
        guard !searchFocused else { return }
        guard !selectedBooksInOrder.isEmpty else { return }
        booksPendingDelete = selectedBooksInOrder
    }

    private func handleEscape() {
        if searchFocused { searchFocused = false; return }
        if !searchText.isEmpty { searchText = ""; return }
        if !selectedBookIDs.isEmpty { clearSelection(); return }
        if inspectorOpen { inspectorOpen = false }
    }
}

// MARK: - Marquee + frame tracking

enum MarqueeState: Equatable {
    case inactive
    case active(rect: CGRect)

    var rect: CGRect? {
        if case .active(let rect) = self { return rect }
        return nil
    }
}

struct CardFramePreference: PreferenceKey {
    static let defaultValue: [Book.ID: CGRect] = [:]
    static func reduce(value: inout [Book.ID: CGRect], nextValue: () -> [Book.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
