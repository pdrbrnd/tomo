import SwiftUI
import AppKit
import PhosphorSwift

struct LibraryView: View {
    let state: AppState

    @State private var selectedBookIDs: Set<Book.ID> = []
    @State private var selectionAnchor: Book.ID?
    @State private var inspectorOpen = false
    @AppStorage("sidebar.open") private var sidebarOpen = false
    @State private var searchText = ""
    @State private var selectedLanguage: String?
    @State private var selectedCollection: UUID?
    @State private var booksPendingDelete: [Book] = []
    @State private var collectionPendingDelete: Collection?
    @State private var externalDropTargeted = false
    @State private var marquee: MarqueeState = .inactive
    @State private var cardFrames: [Book.ID: CGRect] = [:]
    @State private var contextMenuBookID: Book.ID?
    @State private var dragEndPollingTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let inspectorWidth: CGFloat = 332
    /// Concentric corners: window radius (30) − pane inset (8) = 22 (panel
    /// radius). 8pt gap reads as a comfortable, intentional inset.
    private static let paneInset: CGFloat = 8
    private static let inspectorPaneWidth: CGFloat = inspectorWidth + paneInset * 2

    private static let sidebarWidth: CGFloat = 232
    private static let sidebarPaneWidth: CGFloat = sidebarWidth + paneInset * 2

    /// Collection + language are independent axes AND'd with each other and
    /// with the search query. Standard "OR within an axis, AND between axes"
    /// — degenerate to single-select since each axis only holds one value.
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
        return bySearch.filter { book in
            (selectedCollection.map { book.collectionIDs.contains($0) } ?? true) &&
            (selectedLanguage.map { book.locale == $0 } ?? true)
        }
    }

    /// "Search" → "Search Sci-Fi" / "Search Portuguese" when a scope is
    /// active. Collection wins over language when both are set, since the
    /// collection is the more specific scope.
    private var searchPlaceholder: String {
        if let id = selectedCollection,
           let collection = state.collections.first(where: { $0.id == id }) {
            return "Search \(collection.name)"
        }
        if let lang = selectedLanguage {
            let display = Locale.current.localizedString(forIdentifier: lang) ?? lang
            return "Search \(display)"
        }
        return "Search"
    }

    private var collectionCounts: [UUID: Int] {
        var dict: [UUID: Int] = [:]
        for book in state.books {
            for cid in book.collectionIDs {
                dict[cid, default: 0] += 1
            }
        }
        return dict
    }

    /// Selection resolved against the full library, not the filtered grid.
    /// Drives the inspector — a search/filter change must not make the
    /// inspector forget the user's selection.
    private var inspectorBooks: [Book] {
        state.books.filter { selectedBookIDs.contains($0.id) }
    }

    /// The book shown in the single-book inspector branch.
    private var inspectorBook: Book? {
        inspectorBooks.count == 1 ? inspectorBooks.first : nil
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

    /// Pre-filtered multi-selection device context for the inspector.
    private func multiDeviceInfo(for books: [Book]) -> BookInspector.MultiDeviceInfo? {
        guard let device = state.device else { return nil }
        let sendable = books.filter { device.canAccept($0) }
        return BookInspector.MultiDeviceInfo(
            displayName: device.displayName,
            sendableCount: sendable.count
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarOpen {
                sidebarPane
                    .frame(width: Self.sidebarPaneWidth)
                    .transition(sidebarTransition)
                    // Render above mainPane so the pane's drop-shadow
                    // extends *over* the canvas instead of being covered by
                    // mainPane's opaque background (which produced a hard
                    // cutoff at the seam).
                    .zIndex(1)
            }

            mainPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if inspectorOpen {
                inspectorPane
                    .frame(width: Self.inspectorPaneWidth)
                    .transition(inspectorTransition)
                    .zIndex(1)
            }
        }
        .ignoresSafeArea(.all)
        .overlay(alignment: .bottom) {
            // Window-level chrome floats above the panes so the toggle
            // buttons stay in the same screen position whether or not the
            // sidebar / inspector are open. Tapping the same spot toggles
            // open/closed — no separate "close X" inside each pane.
            BottomChrome(
                searchText: $searchText,
                searchFocused: $searchFocused,
                searchPlaceholder: searchPlaceholder,
                sidebarOpen: sidebarOpen,
                inspectorOpen: inspectorOpen,
                onToggleSidebar: { sidebarOpen.toggle() },
                onToggleInspector: { inspectorOpen.toggle() }
            )
        }
        .background(WindowCustomizer())
        .frame(minWidth: 880, minHeight: 600)
        .animation(paneAnimation, value: inspectorOpen)
        .animation(paneAnimation, value: sidebarOpen)
        .task { await state.loadBooks() }
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
        .confirmationDialog(
            collectionPendingDelete.map { "Delete \"\($0.name)\"?" } ?? "",
            isPresented: Binding(
                get: { collectionPendingDelete != nil },
                set: { if !$0 { collectionPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let collection = collectionPendingDelete {
                    Task { await state.deleteCollection(id: collection.id) }
                    if selectedCollection == collection.id {
                        selectedCollection = nil
                    }
                }
                collectionPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                collectionPendingDelete = nil
            }
        } message: {
            Text("Books in this collection are kept; only the grouping is removed.")
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
        ZStack {
            Theme.canvas
                .ignoresSafeArea()

            gridArea
                .ignoresSafeArea(.all)

            // Top chrome: device tile at top-center ("the notch"). Floats
            // over the grid; the grid scrolls under it.
            if let device = state.device {
                VStack {
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
                    .padding(.top, Theme.Spacing.lg)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .transition(deviceTileTransition)
            }

            if externalDropTargeted {
                DropOverlay()
                    .ignoresSafeArea(.all)
                    .transition(.opacity)
            }

            keyboardShortcuts
        }
        .animation(deviceTileAnimation, value: state.device?.displayName)
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
            placeholderText(emptyFilteredMessage)
        } else {
            grid
        }
    }

    private var emptyFilteredMessage: String {
        if !searchText.isEmpty {
            return "Nothing matches “\(searchText)”."
        }
        if let id = selectedCollection,
           let collection = state.collections.first(where: { $0.id == id }) {
            return "No books in “\(collection.name)” yet."
        }
        if let lang = selectedLanguage {
            let display = Locale.current.localizedString(forIdentifier: lang) ?? lang
            return "No books in \(display)."
        }
        return "No books match the current filters."
    }

    private var grid: some View {
        GeometryReader { proxy in
            // Bigger than the rest of the spacing scale on purpose: gives the
            // floating chrome (top-center notch, bottom toggles, traffic
            // lights) room to breathe over the canvas without crowding the
            // first/last cards.
            let margin: CGFloat = 62
            let gutter: CGFloat = Theme.Spacing.xxl
            let minCardWidth: CGFloat = 168
            let maxCardWidth: CGFloat = 224

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
                    // Equal margin on all four sides — the chrome floats over
                    // the canvas and cards scroll under it at the top and
                    // bottom. The chrome's shadow + opaque pill give natural
                    // separation, no extra reserve needed.
                    .padding(margin)

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
            deviceStatus: deviceStatus(for: book),
            cardWidth: cardWidth
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
        bookMenuItem("Show in Finder", icon: .folderOpen) {
            NSWorkspace.shared.activateFileViewerSelecting([book.fileURL])
            dismiss()
        }
        ShareLink(item: book.fileURL) {
            HStack(spacing: 9) {
                Icon(symbol: .share, weight: .regular, size: 13)
                    .frame(width: 14)
                Text("Share…")
            }
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
        // Surface "Remove from <Collection>" only when a collection is the
        // active scope and the book is in it — that's the moment the user
        // is most likely to want to remove it from there. Removing from
        // arbitrary collections is done via drag-out / inspector.
        if let collectionID = selectedCollection,
           let collection = state.collections.first(where: { $0.id == collectionID }),
           book.collectionIDs.contains(collectionID) {
            MenuDivider()
            bookMenuItem("Remove from \(collection.name)", icon: .minus, destructive: true) {
                Task { await state.removeBook(book, from: collectionID) }
                dismiss()
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
            }
        }
        ShareLink(items: books.map(\.fileURL)) {
            HStack(spacing: 9) {
                Icon(symbol: .share, weight: .regular, size: 13)
                    .frame(width: 14)
                Text("Share \(books.count)…")
            }
        }
        if let collectionID = selectedCollection,
           let collection = state.collections.first(where: { $0.id == collectionID }) {
            let inCollection = books.filter { $0.collectionIDs.contains(collectionID) }
            if !inCollection.isEmpty {
                MenuDivider()
                bookMenuItem("Remove \(inCollection.count) from \(collection.name)", icon: .minus, destructive: true) {
                    Task {
                        for book in inCollection {
                            await state.removeBook(book, from: collectionID)
                        }
                    }
                    dismiss()
                }
            }
        }
        MenuDivider()
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

    // MARK: - Sidebar

    private var sidebarPane: some View {
        LibrarySidebar(
            selectedCollection: $selectedCollection,
            selectedLanguage: $selectedLanguage,
            totalBooks: state.books.count,
            collections: state.collections,
            collectionCounts: collectionCounts,
            languageCounts: languageCounts,
            onCreateCollection: { name in
                Task { await state.createCollection(named: name) }
            },
            onRenameCollection: { id, newName in
                Task { await state.renameCollection(id: id, to: newName) }
            },
            onRequestDeleteCollection: { collection in
                collectionPendingDelete = collection
            },
            onDropOnCollection: { drag, collectionID in
                let bookIDs = drag.bookIDs
                let books = bookIDs.compactMap { id in state.books.first(where: { $0.id == id }) }
                guard !books.isEmpty else { return false }
                Task {
                    for book in books {
                        await state.addBook(book, to: collectionID)
                    }
                }
                return true
            }
        )
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 0.5)
        )
        .softShadow(elevated: true)
        .padding(Self.paneInset)
    }

    private var sidebarTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .move(edge: .leading).combined(with: .opacity)
    }

    // MARK: - Inspector

    private var inspectorPane: some View {
        BookInspector(
            book: inspectorBook,
            device: inspectorBook.flatMap { deviceContext(for: $0) },
            multiBooks: inspectorBooks.count > 1 ? inspectorBooks : nil,
            multiDeviceInfo: inspectorBooks.count > 1 ? multiDeviceInfo(for: inspectorBooks) : nil,
            profiles: state.profiles,
            onUpdate: { updated in
                Task { await state.updateBook(updated) }
            },
            onClassify: {
                guard let book = inspectorBook else { return nil }
                let url = book.fileURL
                let profiles = state.profiles
                return await Task.detached {
                    Classifier.classifyEPUB(at: url, profiles: profiles)
                }.value
            },
            onSetCoverFromFile: { url in
                if let book = inspectorBook {
                    Task { await state.setCover(for: book, fromFile: url) }
                }
            },
            onSetCoverFromImage: { image in
                if let book = inspectorBook {
                    Task { await state.setCover(for: book, image: image) }
                }
            },
            onRemoveCover: {
                if let book = inspectorBook {
                    Task { await state.removeCover(for: book) }
                }
            },
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
            onRequestDelete: { if let book = inspectorBook { booksPendingDelete = [book] } },
            onSendMultiToDevice: {
                guard let device = state.device else { return }
                let sendable = inspectorBooks.filter { device.canAccept($0) }
                Task { await state.sendBooksToDevice(sendable) }
            },
            onRequestDeleteMulti: { booksPendingDelete = inspectorBooks }
        )
        .frame(width: Self.inspectorWidth)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 0.5)
        )
        .softShadow(elevated: true)
        .padding(Self.paneInset)
    }

    private var inspectorTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .move(edge: .trailing).combined(with: .opacity)
    }

    /// Single animation curve shared by sidebar + inspector pane open/close.
    private var paneAnimation: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.18)
        }
        return .smooth(duration: 0.32, extraBounce: 0.10)
    }

    /// Notch-style device tile entrance: scales up from a thin sliver at
    /// the top edge with a soft fade. Anchored to `.top` so the growth
    /// reads as "revealing from above" rather than "expanding outward".
    private var deviceTileTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .scale(scale: 0.6, anchor: .top).combined(with: .opacity)
    }

    private var deviceTileAnimation: Animation {
        if reduceMotion {
            return .easeOut(duration: 0.18)
        }
        return .spring(duration: 0.36, bounce: 0.10)
    }

    private func isOnDevice(_ book: Book) -> Bool {
        guard let device = state.device else { return false }
        return state.deviceFilenames.contains(device.deviceFilename(for: book))
    }

    /// Resolves the card's relation to the connected device. Drives the
    /// cover dim (missing) and the on-device check badge (present).
    private func deviceStatus(for book: Book) -> BookCardDeviceStatus {
        guard state.device != nil else { return .noDevice }
        return isOnDevice(book) ? .onDevice : .missingFromDevice
    }

    // MARK: - Keyboard shortcuts

    private var keyboardShortcuts: some View {
        ZStack {
            Button("") { inspectorOpen.toggle() }
                .keyboardShortcut("i", modifiers: .command)
            Button("") { sidebarOpen.toggle() }
                .keyboardShortcut("s", modifiers: [.control, .command])
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
        if inspectorOpen { inspectorOpen = false; return }
        if sidebarOpen { sidebarOpen = false }
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
