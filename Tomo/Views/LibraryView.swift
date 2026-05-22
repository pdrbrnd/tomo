import AppKit
import SwiftUI
import os

struct LibraryView: View {
    let state: AppState

    @State private var selectedBookIDs: Set<Book.ID> = []
    @State private var selectionAnchor: Book.ID?
    @State private var inspectorOpen = false
    @AppStorage("sidebar.open") private var sidebarOpen = false
    @State private var searchText = ""
    @State private var selectedLanguage: String?
    @State private var selectedCollection: UUID?
    @State private var selectedDeviceFilter: DeviceFilter?
    @State private var booksPendingDelete: [Book] = []
    @State private var collectionPendingDelete: Collection?
    @State private var coverGalleryBook: Book?
    @State private var externalDropTargeted = false
    @State private var marquee: MarqueeState = .inactive
    @State private var cardFrames: [Book.ID: CGRect] = [:]
    /// Live column count from the grid's GeometryReader. Drives ↑/↓ arrow-key
    /// navigation (which moves selection by `gridColumnCount` items at a time).
    @State private var gridColumnCount: Int = 1
    @State private var contextMenuBookID: Book.ID?
    @State private var contextMenuSourceID: String?
    @State private var dragEndPollingTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    /// Per-plugin search state keyed by plugin id. Empty when no search is
    /// active. Each enabled plugin gets an entry the moment a search kicks
    /// off (`.loading`), then transitions to `.loaded(_)` or `.failed(_)`.
    /// Section views read state per plugin to render their own headers and
    /// rows without the parent needing to fan out signals.
    @State private var pluginSearchStates: [String: PluginSearchState] = [:]
    /// Section ids the user has manually collapsed within the current search
    /// session. Cleared when the search field empties so each new search
    /// session starts with every section expanded.
    @State private var collapsedSectionIDs: Set<String> = []
    /// Source sections the user has "shown all" for. Same persistence rule
    /// as `collapsedSectionIDs` — within-session, reset on search-empty.
    @State private var expandedSectionIDs: Set<String> = []
    /// Cancellable handle to the in-flight plugin search. Replaced on every
    /// keystroke so older queries can't clobber newer ones.
    @State private var pluginSearchTask: Task<Void, Never>?
    /// Per-source-card download state, keyed by `PluginResult.id`. Drives the
    /// in-place card morph when downloading + importing.
    @State private var downloadStates: [String: CardDownloadState] = [:]
    /// In-flight `URLSessionTask`s keyed by `PluginResult.id`, captured the
    /// instant the task is created so the user's cancel click can hit
    /// `task.cancel()` even before the first byte arrives.
    @State private var downloadTasks: [String: URLSessionTask] = [:]
    /// Selection slot for source results — separate from `selectedBookIDs`
    /// because source items aren't part of the multi-select model. Setting
    /// this clears `selectedBookIDs` (and vice versa) so only one item can
    /// be inspected at a time.
    @State private var selectedSourceID: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let inspectorWidth: CGFloat = 332
    private static let paneInset: CGFloat = Theme.Chrome.paneInset
    private static let inspectorPaneWidth: CGFloat = inspectorWidth + paneInset * 2

    private static let sidebarWidth: CGFloat = 232
    private static let sidebarPaneWidth: CGFloat = sidebarWidth + paneInset * 2

    /// Flat list of every loaded plugin result, in the order plugins are
    /// enabled. Derived from `pluginSearchStates` — never mutate the array
    /// directly; mutate the state map.
    private var pluginResults: [PluginResult] {
        state.enabledPlugins.flatMap { pluginSearchStates[$0.id]?.results ?? [] }
    }

    /// Loaded results for one plugin, in plugin-returned order. Source
    /// sections in the search list read this.
    private func results(forPluginID id: String) -> [PluginResult] {
        pluginSearchStates[id]?.results ?? []
    }

    /// True while we're searching but the user hasn't typed enough to start a
    /// query (e.g. the field is empty). Drives the grid/list switch.
    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Collection + language are independent axes AND'd with each other and
    /// with the search query. Standard "OR within an axis, AND between axes"
    /// — degenerate to single-select since each axis only holds one value.
    private var filteredBooks: [Book] {
        // Same parser used for plugin search. Library books get the same
        // structured filters (`format:epub`, `author:saramago`, etc.) so the
        // search bar grammar is honoured uniformly across both halves.
        let parsedQuery = QueryParser.parse(searchText)
        let bySearch: [Book]
        if parsedQuery.isEmpty {
            bySearch = state.books
        } else {
            bySearch = state.books.filter { bookMatches(book: $0, query: parsedQuery) }
        }
        return bySearch.filter { book in
            (selectedCollection.map { book.collectionIDs.contains($0) } ?? true)
                && (selectedLanguage.map { book.locale == $0 } ?? true)
                && (selectedDeviceFilter.map { matches(deviceFilter: $0, book: book) } ?? true)
        }
    }

    /// Applies parsed search-bar tokens to a single library book. Free text
    /// matches title or any author (legacy behaviour); structured fields are
    /// AND'd in. `publisher` / `isbn` aren't carried on `Book`, so we only
    /// honour them on the plugin side.
    private func bookMatches(book: Book, query: PluginQuery) -> Bool {
        if !query.text.isEmpty {
            let needle = query.text.lowercased()
            let titleMatch = book.title.lowercased().contains(needle)
            let authorMatch = book.authors.contains { $0.lowercased().contains(needle) }
            if !titleMatch && !authorMatch { return false }
        }
        if let title = query.title?.lowercased(), !title.isEmpty,
            !book.title.lowercased().contains(title)
        {
            return false
        }
        if let author = query.author?.lowercased(), !author.isEmpty,
            !book.authors.contains(where: { $0.lowercased().contains(author) })
        {
            return false
        }
        if let format = query.format?.lowercased(), !format.isEmpty,
            book.fileURL.pathExtension.lowercased() != format
        {
            return false
        }
        if let language = query.language?.lowercased(), !language.isEmpty {
            // BCP 47 prefix match: `pt` matches `pt`, `pt-PT`, `pt-BR`.
            let bookLocale = book.locale.lowercased()
            if bookLocale != language && !bookLocale.hasPrefix(language + "-") {
                return false
            }
        }
        if let year = query.year, book.year != year {
            return false
        }
        return true
    }

    private func matches(deviceFilter: DeviceFilter, book: Book) -> Bool {
        switch deviceFilter {
        case .onDevice: return isOnDevice(book)
        case .notOnDevice: return !isOnDevice(book)
        }
    }

    /// Library results first (full filter), then source results (dedup'd
    /// against the library). Source results never appear without an active
    /// search query.
    private var gridItems: [LibraryItem] {
        let libraryItems = filteredBooks.map(LibraryItem.book)
        guard !searchText.isEmpty, !pluginResults.isEmpty else {
            return libraryItems
        }
        // Dedup: case-insensitive title + first-author match against library.
        // Productionisation will reuse the duplicate-detection logic from the
        // import path; for the spike, exact-ish equality is enough.
        let libraryFingerprints: Set<String> = Set(state.books.map(libraryFingerprint(forBook:)))
        // Apply the parsed query's structured filters to plugin results too.
        // Plugins are expected to honour `format` / `language` / `year` on
        // their side, but not all do (gutenberg.js only consumes free text,
        // for example). Filtering here is the safety net so a typed
        // `format:pdf` doesn't leak EPUB-only plugin hits into the grid.
        let parsedQuery = QueryParser.parse(searchText)
        let sourceItems: [LibraryItem] =
            pluginResults
            .filter { !libraryFingerprints.contains(libraryFingerprint(forResult: $0)) }
            .filter { resultMatches(result: $0, query: parsedQuery) }
            .prefix(30)
            .map(LibraryItem.source)
        return libraryItems + sourceItems
    }

    private func resultMatches(result: PluginResult, query: PluginQuery) -> Bool {
        if let format = query.format?.lowercased(), !format.isEmpty,
            result.format.lowercased() != format
        {
            return false
        }
        if let language = query.language?.lowercased(), !language.isEmpty {
            let resultLocale = result.language.lowercased()
            // Empty-language plugin results are kept — the plugin didn't
            // tell us, we don't second-guess. The library-side filter is
            // strict; plugin results are advisory.
            if !resultLocale.isEmpty,
                resultLocale != language,
                !resultLocale.hasPrefix(language + "-")
            {
                return false
            }
        }
        if let year = query.year, let resultYear = result.year, resultYear != year {
            return false
        }
        return true
    }

    private func libraryFingerprint(forBook book: Book) -> String {
        "\(book.title.lowercased())|\(book.authors.first?.lowercased() ?? "")"
    }

    private func libraryFingerprint(forResult result: PluginResult) -> String {
        "\(result.title.lowercased())|\(result.authors.first?.lowercased() ?? "")"
    }

    /// "Search" → "Search Sci-Fi" / "Search Portuguese" when a scope is
    /// active. Collection wins over language when both are set, since the
    /// collection is the more specific scope.
    private var searchPlaceholder: String {
        if let id = selectedCollection,
            let collection = state.collections.first(where: { $0.id == id })
        {
            return "Search \(collection.name)"
        }
        if let lang = selectedLanguage {
            let display = Locale.current.localizedString(forIdentifier: lang) ?? lang
            return "Search \(display)"
        }
        return "Search"
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

    /// Source result currently selected, if any. Resolved against the live
    /// `pluginResults` so a re-search invalidates a stale selection cleanly.
    private var inspectedSource: PluginResult? {
        guard let id = selectedSourceID else { return nil }
        return pluginResults.first(where: { $0.id == id })
    }

    /// Selected books in the order they appear in the current filtered grid.
    private var selectedBooksInOrder: [Book] {
        filteredBooks.filter { selectedBookIDs.contains($0.id) }
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
        .overlay(alignment: .topLeading) {
            // Library folder pill — replaces the old Settings pane. Sits
            // immediately to the right of the traffic lights at the same
            // vertical center; floats over both panes so it stays put when
            // the sidebar opens. Vertical center matches traffic-light
            // center: lights are nudged down by `trafficLightInset` (10)
            // from their default ~14pt; their visual center is therefore
            // ~24pt from the window top. The pill is ~24pt tall, so
            // top padding ≈ 24 − 12 ≈ 12pt aligns the centers.
            LibraryFolderPicker(
                folder: state.libraryFolder,
                setFolder: { state.libraryFolder = $0 },
                clearFolder: { state.libraryFolder = nil }
            )
            .padding(.leading, 90)
            .padding(.top, 14)
        }
        .ignoresSafeArea(.all)
        .overlay(alignment: .bottom) {
            // Window-level chrome floats above the panes so the toggle
            // buttons stay in the same screen position whether or not the
            // sidebar / inspector are open. Tapping the same spot toggles
            // open/closed — no separate "close X" inside each pane.
            BottomChrome(
                state: state,
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
        .task(id: state.libraryFolder) { await state.syncWithDisk() }
        .onChange(of: searchText) { _, newValue in
            schedulePluginSearch(for: newValue)
            // Each new search session starts fresh. Within a session
            // (incremental keystrokes) the collapse / show-more state
            // persists so a refined query doesn't undo the user's choices.
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                collapsedSectionIDs = []
                expandedSectionIDs = []
            }
        }
        .onChange(of: state.enabledPluginIDs) { _, newSet in
            // Drop state for plugins that are no longer enabled.
            pluginSearchStates = pluginSearchStates.filter { newSet.contains($0.key) }
            if newSet.isEmpty {
                pluginSearchTask?.cancel()
                pluginSearchStates = [:]
                selectedSourceID = nil
                state.pluginSearchInFlight = false
            } else if isSearching {
                // Re-run search to pick up any newly-enabled plugins.
                schedulePluginSearch(for: searchText)
            }
        }
        // Switching sidebar scope (collection, language, device filter) clears
        // the search bar. Persisting search across scope changes confused
        // users — they'd land on an empty collection and not realise the
        // search was still narrowing the results.
        .onChange(of: selectedCollection) { _, _ in searchText = "" }
        .onChange(of: selectedLanguage) { _, _ in searchText = "" }
        .onChange(of: selectedDeviceFilter) { _, _ in searchText = "" }
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
            Text(
                booksPendingDelete.count == 1
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
        .sheet(item: $coverGalleryBook) { book in
            CoverGallerySheet(
                book: book,
                onPick: { data in
                    Task { await state.setCover(for: book, fromData: data, ext: "jpg") }
                    coverGalleryBook = nil
                },
                onCancel: { coverGalleryBook = nil }
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
        // ScrollViewReader wraps the ZStack so the keyboard-navigation
        // handlers (siblings of the grid in the ZStack) can ask the grid's
        // ScrollView to bring the new selection into view.
        ScrollViewReader { scrollProxy in
            mainPaneContent(scrollProxy: scrollProxy)
        }
    }

    private func mainPaneContent(scrollProxy: ScrollViewProxy) -> some View {
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

            // Top-right toast surface. The bottom-center spot is occupied by
            // the search chrome; top-right is empty and out of the device
            // tile's lane (top-center).
            if let toast = state.currentToast {
                VStack {
                    HStack {
                        Spacer()
                        ToastView(toast: toast)
                            .padding(.top, Theme.Spacing.lg)
                            .padding(.trailing, Theme.Spacing.lg)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(toast.id)
            }

            keyboardShortcuts(scrollProxy: scrollProxy)
        }
        .onPreferenceChange(GridColumnCountPreference.self) { count in
            gridColumnCount = count
        }
        .animation(deviceTileAnimation, value: state.device?.displayName)
        .animation(reduceMotion ? .easeOut(duration: 0.18) : .snappy(duration: 0.28), value: state.currentToast?.id)
        .dropDestination(for: URL.self) { urls, _ in
            let (accepted, rejected) = urls.reduce(into: ([URL](), [URL]())) { acc, url in
                if LibraryImporter.canImport(url) {
                    acc.0.append(url)
                } else {
                    acc.1.append(url)
                }
            }
            if !rejected.isEmpty {
                let exts =
                    Set(rejected.map { $0.pathExtension.lowercased() })
                    .sorted()
                    .map { ".\($0)" }
                    .joined(separator: ", ")
                state.showToast(
                    .error(
                        "Unsupported file type (\(exts)). Tomo imports \(LibraryImporter.acceptedExtensionsDisplay)."
                    ))
            }
            guard !accepted.isEmpty else { return !rejected.isEmpty }
            Task {
                for url in accepted {
                    await state.importBook(from: url, origin: .manualImport)
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
            emptyLibraryCTA
        } else if isSearching {
            searchResultsList
        } else if state.books.isEmpty {
            placeholderText("Drop a book to begin")
        } else if gridItems.isEmpty {
            placeholderText(emptyFilteredMessage)
        } else {
            grid
        }
    }

    /// First-launch CTA. Replaces a centered "choose a folder" line with
    /// an actual button — the top-left folder pill is still visible, but
    /// users on a fresh launch shouldn't have to find it.
    private var emptyLibraryCTA: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.primary.opacity(Theme.Text.tertiary))
            VStack(spacing: 6) {
                Text("Choose your library folder")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary.opacity(Theme.Text.primary))
                Text("Tomo keeps your books and metadata in a folder of your choosing.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary.opacity(Theme.Text.secondary))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            Button {
                presentLibraryFolderPicker()
            } label: {
                Text("Choose Folder…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Capsule(style: .continuous).fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func presentLibraryFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            state.libraryFolder = url
        }
    }

    private var emptyFilteredMessage: String {
        // Source search is in flight — say so, instead of "nothing matches".
        // The library half may still be empty for the typed query but the
        // plugin half is about to populate, and "nothing matches" reads as a
        // dead-end the user doesn't need to see for ~1s while results land.
        if state.pluginSearchInFlight, !searchText.isEmpty {
            return "Searching sources…"
        }
        if !searchText.isEmpty {
            return "Nothing matches “\(searchText)”."
        }
        if let id = selectedCollection,
            let collection = state.collections.first(where: { $0.id == id })
        {
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
            let margin = Theme.Library.gridMargin
            let gutter = Theme.Spacing.xxl
            let minCardWidth = Theme.Library.minCardWidth
            let maxCardWidth = Theme.Library.maxCardWidth

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
                        ForEach(gridItems) { item in
                            switch item {
                            case .book(let book):
                                bookCell(book, cardWidth: cardWidth)
                            case .source(let result):
                                sourceCell(result, cardWidth: cardWidth)
                            }
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
            .preference(key: GridColumnCountPreference.self, value: cols)
        }
    }

    private static let gridCoordinateSpace = "library.grid"

    // MARK: - Search results list

    /// Sectioned list rendered in place of the grid while a search is active.
    /// Section order: Library first, then one section per enabled plugin in
    /// the order the user enabled them. The library section is always
    /// present (with a quiet "No matches" if empty); plugin sections appear
    /// only for enabled plugins.
    private var searchResultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Self.sectionSpacing) {
                librarySection
                ForEach(state.enabledPlugins) { plugin in
                    sourceSection(for: plugin)
                }
            }
            .padding(.horizontal, Theme.Library.gridMargin)
            .padding(.top, Theme.Library.gridMargin)
            .padding(.bottom, Theme.Library.gridMargin)
            .frame(maxWidth: Self.searchListMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollContentBackground(.hidden)
    }

    /// Cap so the rich rows don't stretch across an ultrawide window
    /// (where they'd read as one continuous strip rather than a list).
    /// Still gives a lot more room than the previous 880pt cap.
    private static let searchListMaxWidth: CGFloat = 1200

    /// Breathing room between sections — bigger than between rows so the
    /// eye reads each section as a separate block.
    private static let sectionSpacing: CGFloat = Theme.Spacing.xl

    /// Vertical gap between rows inside a section.
    private static let rowSpacing: CGFloat = 4

    // MARK: Library section

    private static let librarySectionKey = "__library__"

    @ViewBuilder
    private var librarySection: some View {
        let books = filteredBooks
        let isCollapsed = collapsedSectionIDs.contains(Self.librarySectionKey)
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            SearchSectionHeader(
                title: librarySectionTitle,
                resultCount: books.count,
                isCollapsed: isCollapsed,
                onToggle: { toggleSection(Self.librarySectionKey) }
            )
            if isCollapsed {
                EmptyView()
            } else if books.isEmpty {
                rowPlaceholder("No matches")
            } else {
                ForEach(books) { book in
                    SearchResultRow(
                        item: .book(book),
                        isSelected: selectedBookIDs.contains(book.id),
                        deviceStatus: deviceStatus(for: book),
                        onSelect: { handlePlainClick(book) },
                        onActivate: {
                            handlePlainClick(book)
                            inspectorOpen = true
                        }
                    )
                    .overlay(
                        RightClickCatcher {
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
            }
        }
    }

    // MARK: Source section

    @ViewBuilder
    private func sourceSection(for plugin: PluginSource) -> some View {
        let pluginState = pluginSearchStates[plugin.id]
        let allDeduped = dedupedSourceResults(pluginState?.results ?? [])
        let isExpanded = expandedSectionIDs.contains(plugin.id)
        let visible = isExpanded ? allDeduped : Array(allDeduped.prefix(Self.sourceVisibleCap))
        let hiddenCount = max(0, allDeduped.count - visible.count)
        let isLoading = pluginState?.isLoading ?? false
        let isCollapsed = collapsedSectionIDs.contains(plugin.id)
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            SearchSectionHeader(
                title: plugin.displayName,
                isLoading: isLoading,
                failureMessage: pluginState?.failureMessage,
                // Total deduped count, not visible — signals "there's more
                // here" when the cap is in effect.
                resultCount: isLoading ? nil : allDeduped.count,
                isCollapsed: isCollapsed,
                onToggle: { toggleSection(plugin.id) }
            )
            if isCollapsed {
                EmptyView()
            } else if isLoading && visible.isEmpty {
                // Quiet placeholder while the plugin is still working — keeps
                // the section weight present so the user doesn't see the
                // layout jump as results land.
                rowPlaceholder("Searching…")
            } else if visible.isEmpty, pluginState?.failureMessage == nil {
                rowPlaceholder("No matches")
            } else {
                ForEach(visible) { result in
                    sourceRow(for: result, plugin: plugin)
                }
                if hiddenCount > 0 {
                    showMoreFooter(remaining: hiddenCount) {
                        expandedSectionIDs.insert(plugin.id)
                    }
                }
            }
        }
    }

    /// Maximum source results shown by default. Plugins return whatever they
    /// want; the cap keeps the section scannable. The "Show N more" footer
    /// lifts the cap for that one section when the user wants the full list.
    private static let sourceVisibleCap = 30

    /// Footer button rendered at the bottom of a source section when more
    /// results were fetched than the visible cap.
    private func showMoreFooter(remaining: Int, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Icon(symbol: "chevron.down", weight: .semibold, size: 10)
                Text("Show \(remaining) more")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.primary.opacity(Theme.Text.muted))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    /// Toggles a section's collapsed state. Section ids: plugin id for
    /// source sections, `librarySectionKey` for the library section.
    private func toggleSection(_ key: String) {
        if collapsedSectionIDs.contains(key) {
            collapsedSectionIDs.remove(key)
        } else {
            collapsedSectionIDs.insert(key)
        }
    }

    private func sourceRow(for result: PluginResult, plugin: PluginSource) -> some View {
        SearchResultRow(
            item: .source(result),
            isSelected: selectedSourceID == result.id,
            downloadState: downloadStates[result.id] ?? .idle,
            onSelect: {
                withAnimation(selectionAnimation) {
                    selectedBookIDs = []
                    selectionAnchor = nil
                    selectedSourceID = result.id
                    searchFocused = false
                }
            },
            onActivate: {
                withAnimation(selectionAnimation) {
                    selectedBookIDs = []
                    selectionAnchor = nil
                    selectedSourceID = result.id
                    searchFocused = false
                }
                inspectorOpen = true
            },
            onDownload: {
                Task { await downloadAndImport(result) }
            },
            onCancelDownload: {
                cancelDownload(result)
            }
        )
        .overlay(
            RightClickCatcher {
                selectedBookIDs = []
                selectionAnchor = nil
                selectedSourceID = result.id
                contextMenuSourceID = result.id
            }
        )
        .popover(
            isPresented: Binding(
                get: { contextMenuSourceID == result.id },
                set: { if !$0 { contextMenuSourceID = nil } }
            ),
            arrowEdge: .top
        ) {
            VStack(alignment: .leading, spacing: 0) {
                sourceMenu(for: result) { contextMenuSourceID = nil }
            }
            .menuPopoverContainer()
        }
    }

    // MARK: Section helpers

    /// Active-collection name wins, otherwise generic "Library". Language
    /// scope doesn't change the header — the sidebar already tells the user
    /// which language is active, so we don't repeat it here.
    private var librarySectionTitle: String {
        if let id = selectedCollection,
            let collection = state.collections.first(where: { $0.id == id })
        {
            return collection.name
        }
        return "Library"
    }

    /// Context-menu label for the source download action. Surfaces the
    /// active collection so the user knows where the book will land, without
    /// needing a separate subtitle in the section header.
    private var downloadMenuLabel: String {
        if let id = selectedCollection,
            let collection = state.collections.first(where: { $0.id == id })
        {
            return "Download to \(collection.name)"
        }
        return "Download to Library"
    }

    /// Drops plugin results that fingerprint-match a library book. Doesn't
    /// cap — `sourceSection` applies the visible cap with a "Show N more"
    /// expansion so the user can see everything the plugin actually returned.
    private func dedupedSourceResults(_ results: [PluginResult]) -> [PluginResult] {
        guard !results.isEmpty else { return [] }
        let libraryFingerprints: Set<String> = Set(state.books.map(libraryFingerprint(forBook:)))
        return results.filter {
            !libraryFingerprints.contains(libraryFingerprint(forResult: $0))
        }
    }

    private func rowPlaceholder(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.primary.opacity(Theme.Text.tertiary))
            // Same horizontal padding as a row so empty-state copy sits
            // under the section title (not indented past the thumb).
            .padding(.horizontal, 12)
            .padding(.vertical, Theme.Spacing.md)
    }

    private func sourceCell(_ result: PluginResult, cardWidth: CGFloat) -> some View {
        BookCard(
            item: .source(result),
            isSelected: selectedSourceID == result.id,
            downloadState: downloadStates[result.id] ?? .idle,
            isCoverLoading: result.coverURL == nil && state.pluginSearchInFlight,
            cardWidth: cardWidth,
            onSourceDownload: {
                Task { await downloadAndImport(result) }
            },
            onCancelDownload: {
                cancelDownload(result)
            }
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                withAnimation(selectionAnimation) {
                    selectedBookIDs = []
                    selectionAnchor = nil
                    selectedSourceID = result.id
                }
                searchFocused = false
                inspectorOpen = true
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                // Match library-book behaviour: click selects, ⌘I opens.
                // Cross-clear the other selection so only one inspectable
                // item exists at a time.
                withAnimation(selectionAnimation) {
                    selectedBookIDs = []
                    selectionAnchor = nil
                    selectedSourceID = result.id
                }
                searchFocused = false
            }
        )
        .overlay(
            RightClickCatcher {
                selectedBookIDs = []
                selectionAnchor = nil
                selectedSourceID = result.id
                contextMenuSourceID = result.id
            }
        )
        .popover(
            isPresented: Binding(
                get: { contextMenuSourceID == result.id },
                set: { if !$0 { contextMenuSourceID = nil } }
            ),
            arrowEdge: .top
        ) {
            VStack(alignment: .leading, spacing: 0) {
                sourceMenu(for: result) { contextMenuSourceID = nil }
            }
            .menuPopoverContainer()
        }
    }

    @ViewBuilder
    private func sourceMenu(for result: PluginResult, dismiss: @escaping () -> Void) -> some View {
        bookMenuItem("Show Details", icon: "info.circle") {
            selectedSourceID = result.id
            inspectorOpen = true
            dismiss()
        }
        let state = downloadStates[result.id] ?? .idle
        bookMenuItem(downloadMenuLabel, icon: "icloud.and.arrow.down") {
            if state == .idle || state == .error {
                Task { await downloadAndImport(result) }
            }
            dismiss()
        }
        if let url = result.detailURL {
            Link(destination: url) {
                HStack(spacing: 9) {
                    Icon(symbol: "safari", weight: .regular, size: 13)
                        .frame(width: 14)
                    Text("Open in Browser")
                }
            }
        }
    }

    /// Debounces plugin search by 300ms then runs every enabled plugin in
    /// turn, transitioning each plugin's per-section state from `.loading`
    /// → `.loaded` / `.failed` as its call settles. Cancels any in-flight
    /// task so older queries can't overwrite newer ones. One failing plugin
    /// surfaces in its own section header without taking down the others.
    private func schedulePluginSearch(for query: String) {
        pluginSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let plugins = state.enabledPlugins
        guard !trimmed.isEmpty, !plugins.isEmpty else {
            pluginSearchStates = [:]
            state.pluginSearchInFlight = false
            return
        }
        // Parse the search bar into structured fields. `field:value` tokens
        // become `query.title`, `query.author`, etc.; everything else stays
        // in `query.text`. The sidebar's selected language is layered on
        // top of any user-typed `language:` token — explicit syntax wins.
        let typedQuery = QueryParser.parse(trimmed)
        guard !typedQuery.isEmpty else {
            pluginSearchStates = [:]
            state.pluginSearchInFlight = false
            return
        }
        let parsedQuery = mergeSidebarScope(into: typedQuery)
        // Flip every enabled plugin to .loading up front so the section
        // headers spin from the first keystroke after debounce, not only
        // once results land. Disabled plugins get pruned out of the dict.
        var initial: [String: PluginSearchState] = [:]
        for plugin in plugins {
            initial[plugin.id] = .loading
        }
        pluginSearchStates = initial
        state.pluginSearchInFlight = true
        pluginSearchTask = Task { @MainActor in
            defer { state.pluginSearchInFlight = false }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }

            // Run each enabled plugin in turn. With 2-3 plugins typical,
            // sequential is plenty fast (~1s worst case after the 300ms
            // debounce) and dodges the cross-actor region-isolation gymnastics
            // a TaskGroup would need under Swift 6 strict concurrency. One
            // slow plugin blocks the next; revisit when that becomes a real
            // problem.
            for plugin in plugins {
                if Task.isCancelled { break }
                do {
                    let raw = try await plugin.search(parsedQuery)
                    if Task.isCancelled { break }
                    // Client-side language filter for plugins that don't
                    // honour `query.language` server-side. Empty result
                    // language is kept — plugin didn't tell us, we don't
                    // second-guess.
                    let filtered = filterByLanguage(raw, language: parsedQuery.language)
                    pluginSearchStates[plugin.id] = .loaded(filtered)
                } catch {
                    let message =
                        (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    pluginSearchStates[plugin.id] = .failed(message)
                    pluginLogger.error(
                        "plugin \(plugin.id, privacy: .public) search failed: \(message, privacy: .public)"
                    )
                }
            }

            guard !Task.isCancelled else { return }
            // Cover enrichment runs against the union of loaded results.
            // Per-plugin states are updated in place so each section's rows
            // refresh independently as covers land.
            let snapshot = pluginSearchStates.values.flatMap(\.results)
            if snapshot.contains(where: { $0.coverURL == nil }) {
                let enrichments = await PluginCoverEnricher.enrich(snapshot)
                guard !Task.isCancelled else { return }
                for (id, state) in pluginSearchStates {
                    guard case .loaded(let results) = state else { continue }
                    let enriched = results.map { result in
                        guard result.coverURL == nil,
                            let url = enrichments[result.id]
                        else { return result }
                        return result.with(coverURL: url)
                    }
                    pluginSearchStates[id] = .loaded(enriched)
                }
            }
        }
    }

    /// Layers the sidebar's selected language into a parsed query. Explicit
    /// `language:` tokens typed by the user win — sidebar scope is the
    /// default, not an override.
    private func mergeSidebarScope(into query: PluginQuery) -> PluginQuery {
        guard query.language == nil, let lang = selectedLanguage, !lang.isEmpty else {
            return query
        }
        return PluginQuery(
            text: query.text,
            title: query.title,
            author: query.author,
            language: lang,
            isbn: query.isbn,
            format: query.format,
            year: query.year,
            publisher: query.publisher
        )
    }

    /// Drops plugin results whose declared language disagrees with the
    /// requested filter. BCP 47 prefix match — `pt` matches `pt`, `pt-PT`,
    /// `pt-BR`. Results with no declared language stay; the plugin didn't
    /// tell us, so we don't filter them out.
    private func filterByLanguage(
        _ results: [PluginResult], language: String?
    ) -> [PluginResult] {
        guard let language, !language.isEmpty else { return results }
        let needle = language.lowercased()
        return results.filter { result in
            let tag = result.language.lowercased()
            if tag.isEmpty { return true }
            return tag == needle || tag.hasPrefix(needle + "-")
        }
    }

    /// Removes a single result from its plugin's `.loaded` list. Used when a
    /// source result is converted into a library book after download and
    /// the source card should disappear in the same frame the library row
    /// appears.
    private func removeSourceResult(id: String, pluginID: String) {
        guard case .loaded(let results) = pluginSearchStates[pluginID] else { return }
        pluginSearchStates[pluginID] = .loaded(results.filter { $0.id != id })
    }

    /// Click → inspect → download path and the double-click direct-download
    /// path both funnel here. Drives the per-card morph and pipes the file
    /// through the existing import pipeline so plugin-sourced books look
    /// identical to manually-imported ones afterwards.
    private func downloadAndImport(_ result: PluginResult) async {
        guard let source = state.plugin(withID: result.pluginID) else {
            state.showToast(.error("Plugin '\(result.pluginID)' is no longer loaded."))
            return
        }
        // Reentry guard. Two rapid double-clicks both schedule a Task before
        // either runs — the gesture-side check can't see the in-flight state
        // until the first Task's sync prefix executes. Without this guard,
        // both Tasks proceed in parallel and the file gets written twice.
        let existing = downloadStates[result.id] ?? .idle
        guard existing == .idle || existing == .error else { return }
        downloadStates[result.id] = .downloading(progress: nil)
        defer {
            // Idle reset happens in the success branch (after grid swaps the
            // card for its library counterpart); error path resets here.
        }
        do {
            let downloadURL = try await source.download(result)
            let tempURL = try await fetchToTempFile(
                url: downloadURL,
                format: result.format,
                fallbackExpectedBytes: result.sizeBytes.map(Int64.init),
                onTaskCreated: { task in
                    downloadTasks[result.id] = task
                },
                onProgress: { progress in
                    // Late callbacks may land after we've moved past `.downloading`
                    // (e.g. into .importing or .error). Only update if we're still
                    // in the downloading phase to avoid clobbering a later state.
                    if case .downloading = downloadStates[result.id] {
                        downloadStates[result.id] = .downloading(progress: progress)
                    }
                }
            )
            downloadTasks[result.id] = nil
            downloadStates[result.id] = .importing
            let importedBook = await state.importBook(
                from: tempURL,
                origin: .source(id: result.pluginID, ref: result.id),
                collection: selectedCollection
            )
            try? FileManager.default.removeItem(at: tempURL)
            // Cover fallback for plugins that supply a `coverURL` but ship a
            // book file without an embedded cover. The importer extracts
            // covers from the file itself; if that path comes back empty
            // and the plugin gave us a URL, fetch it. The user already
            // initiated this network activity by clicking Download, so
            // Principle 5 ("no network without user action") is satisfied.
            //
            // Pass the *current* book from state.books (which carries the
            // collection memberships assigned by importBook), not the stale
            // `importedBook` returned by the importer. setCover → updateBook
            // rewrites the sidecar based on the passed book's collectionIDs;
            // using the empty-membership reference would corrupt the sidecar
            // and lose the collection assignment on the next disk sync.
            if let importedBook,
                let current = state.books.first(where: { $0.id == importedBook.id }),
                current.coverPath == nil,
                let coverURL = result.coverURL
            {
                if let data = try? await fetchCoverBytes(from: coverURL) {
                    let ext = inferCoverExtension(url: coverURL, data: data)
                    await state.setCover(for: current, fromData: data, ext: ext)
                }
            }
            downloadStates[result.id] = .added
            try? await Task.sleep(for: .milliseconds(700))
            // Source row disappears after the brief "Added" pulse. The
            // library section already shows the new book in its sorted
            // position — sections are visually distinct in list mode, so
            // showing both transitions reads naturally as "source delivered
            // this book to my library."
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                removeSourceResult(id: result.id, pluginID: result.pluginID)
            }
            downloadStates[result.id] = nil
            if selectedSourceID == result.id {
                selectedSourceID = nil
            }
        } catch {
            downloadTasks[result.id] = nil
            // User-initiated cancel surfaces as URLError.cancelled. Treat it
            // silently: no toast, no red "Failed" capsule — just collapse the
            // card back to its idle state. The user pressed X; they don't
            // need to be told what they just did.
            if let urlError = error as? URLError, urlError.code == .cancelled {
                downloadStates[result.id] = nil
                return
            }
            downloadStates[result.id] = .error
            state.showToast(.error("Download failed: \(error.localizedDescription)"))
            pluginLogger.error("download/import failed: \(error.localizedDescription, privacy: .public)")
            // Reset to idle after a brief error display.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if downloadStates[result.id] == .error {
                    downloadStates[result.id] = nil
                }
            }
        }
    }

    /// User-initiated cancel for an in-flight plugin download. Cancelling the
    /// `URLSessionTask` surfaces as `URLError.cancelled` in `downloadAndImport`,
    /// which collapses the capsule back to idle without a toast.
    private func cancelDownload(_ result: PluginResult) {
        downloadTasks[result.id]?.cancel()
    }

    /// Picks an extension for a cover fetched from a URL. URL path extension
    /// is the cheap signal; a 4-byte magic-number sniff covers the case where
    /// the URL has no extension or a misleading one (e.g. CDN-rewritten URLs).
    private func inferCoverExtension(url: URL, data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        let urlExt = url.pathExtension.lowercased()
        switch urlExt {
        case "png": return "png"
        case "jpg", "jpeg": return "jpg"
        default: return "jpg"
        }
    }

    private func fetchToTempFile(
        url: URL,
        format: String,
        fallbackExpectedBytes: Int64?,
        onTaskCreated: @MainActor @Sendable @escaping (URLSessionTask) -> Void,
        onProgress: @MainActor @Sendable @escaping (Double?) -> Void
    ) async throws -> URL {
        // Apple gotcha: `URLSession.download(from:delegate:)` internally uses a
        // completion handler, which per Apple's docs disables the
        // `URLSessionDownloadDelegate` data callbacks (didWriteData et al). To
        // get reliable progress updates we need a custom session with a
        // session-level delegate plus a plain `downloadTask(with:)` (no
        // completion handler), bridged to async via a continuation.
        let ext = format.lowercased().isEmpty ? "epub" : format.lowercased()
        let dest = FileManager.default.temporaryDirectory
            .appending(path: "tomo-source-\(UUID().uuidString.prefix(8)).\(ext)")
        let delegate = ProgressDownloadDelegate(
            destination: dest,
            fallbackExpectedBytes: fallbackExpectedBytes,
            onTaskCreated: onTaskCreated,
            onProgress: onProgress
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        return try await withCheckedThrowingContinuation { continuation in
            delegate.setContinuation(continuation)
            session.downloadTask(with: url).resume()
        }
    }

    private func bookCell(_ book: Book, cardWidth: CGFloat) -> some View {
        let isSelected = selectedBookIDs.contains(book.id)
        return BookCard(
            item: .book(book),
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
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                let flags = NSEvent.modifierFlags
                if flags.contains(.command) {
                    handleCommandClick(book)
                } else if flags.contains(.shift) {
                    handleShiftClick(book)
                } else {
                    handlePlainClick(book)
                }
            }
        )
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                handlePlainClick(book)
                inspectorOpen = true
            }
        )
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
            selectedSourceID = nil
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
            selectedSourceID = nil
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
            selectedSourceID = nil
            searchFocused = false
        }
    }

    private func clearSelection() {
        withAnimation(selectionAnimation) {
            selectedBookIDs.removeAll()
            selectionAnchor = nil
            selectedSourceID = nil
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
        bookMenuItem("Show Details", icon: "info.circle") {
            selectedBookIDs = [book.id]
            selectionAnchor = book.id
            inspectorOpen = true
            dismiss()
        }
        bookMenuItem("Show in Finder", icon: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([book.fileURL])
            dismiss()
        }
        ShareLink(item: book.fileURL) {
            HStack(spacing: 9) {
                Icon(symbol: "square.and.arrow.up", weight: .regular, size: 13)
                    .frame(width: 14)
                Text("Share…")
            }
        }
        if let device = state.device, device.canAccept(book) {
            MenuDivider()
            if isOnDevice(book) {
                bookMenuItem("Remove from \(device.displayName)", icon: "ipad", destructive: true) {
                    Task { await state.removeFromDevice(book: book) }
                    dismiss()
                }
            } else {
                bookMenuItem("Send to \(device.displayName)", icon: "ipad") {
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
            book.collectionIDs.contains(collectionID)
        {
            MenuDivider()
            bookMenuItem("Remove from \(collection.name)", icon: "minus", destructive: true) {
                Task { await state.removeBook(book, from: collectionID) }
                dismiss()
            }
        }
        MenuDivider()
        bookMenuItem("Move to Trash…", icon: "trash", destructive: true) {
            booksPendingDelete = [book]
            dismiss()
        }
    }

    @ViewBuilder
    private func bulkMenu(for books: [Book], dismiss: @escaping () -> Void) -> some View {
        if let device = state.device {
            let sendable = books.filter { device.canAccept($0) }
            if !sendable.isEmpty {
                bookMenuItem("Send \(sendable.count) to \(device.displayName)", icon: "ipad") {
                    Task { await state.sendBooksToDevice(sendable) }
                    dismiss()
                }
            }
        }
        ShareLink(items: books.map(\.fileURL)) {
            HStack(spacing: 9) {
                Icon(symbol: "square.and.arrow.up", weight: .regular, size: 13)
                    .frame(width: 14)
                Text("Share \(books.count)…")
            }
        }
        if let collectionID = selectedCollection,
            let collection = state.collections.first(where: { $0.id == collectionID })
        {
            let inCollection = books.filter { $0.collectionIDs.contains(collectionID) }
            if !inCollection.isEmpty {
                MenuDivider()
                bookMenuItem("Remove \(inCollection.count) from \(collection.name)", icon: "minus", destructive: true) {
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
        bookMenuItem("Move \(books.count) to Trash…", icon: "trash", destructive: true) {
            booksPendingDelete = books
            dismiss()
        }
    }

    private func bookMenuItem(
        _ title: String,
        icon: String,
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
                .foregroundStyle(.primary.opacity(Theme.Text.tertiary))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sidebar

    private var sidebarPane: some View {
        LibrarySidebar(
            selectedCollection: $selectedCollection,
            selectedLanguage: $selectedLanguage,
            selectedDeviceFilter: $selectedDeviceFilter,
            totalBooks: state.books.count,
            collections: state.collections,
            collectionCounts: state.collectionCounts,
            languageCounts: state.languageCounts,
            deviceConnected: state.device != nil,
            onDeviceCount: state.books.filter { isOnDevice($0) }.count,
            notOnDeviceCount: state.books.filter { !isOnDevice($0) }.count,
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
        .paneShadow()
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
            sourceResult: inspectedSource,
            sourceDownloadState: inspectedSource.flatMap { downloadStates[$0.id] } ?? .idle,
            sourcePluginName: inspectedSource.flatMap { state.plugin(withID: $0.pluginID)?.displayName },
            sourceDownloadIdleTitle: downloadMenuLabel,
            onSourceDownload: {
                if let source = inspectedSource {
                    Task { await downloadAndImport(source) }
                }
            },
            onSourceCancel: {
                if let source = inspectedSource {
                    cancelDownload(source)
                }
            },
            profiles: state.allProfiles,
            allCollections: state.collections,
            onUpdate: { updated in
                Task { await state.updateBook(updated) }
            },
            onClassify: {
                guard let book = inspectorBook else { return nil }
                let url = book.fileURL
                let profiles = state.enabledProfiles
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
            onChooseFromOpenLibrary: {
                if let book = inspectorBook {
                    coverGalleryBook = book
                }
            },
            onAddToCollection: { collectionID in
                if let book = inspectorBook {
                    Task { await state.addBook(book, to: collectionID) }
                }
            },
            onRemoveFromCollection: { collectionID in
                if let book = inspectorBook {
                    Task { await state.removeBook(book, from: collectionID) }
                }
            },
            onCreateCollectionAndAdd: { name in
                guard let book = inspectorBook else { return }
                Task {
                    if let collection = await state.createCollection(named: name) {
                        await state.addBook(book, to: collection.id)
                    }
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
        .paneShadow()
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

    private func keyboardShortcuts(scrollProxy: ScrollViewProxy) -> some View {
        ZStack {
            Button("") { inspectorOpen.toggle() }
                .keyboardShortcut("i", modifiers: .command)
            Button("") { sidebarOpen.toggle() }
                .keyboardShortcut("s", modifiers: [.control, .command])
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { handleSelectAll() }
                .keyboardShortcut("a", modifiers: .command)
            Button("") { handleDeleteShortcut() }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("") { handleEscape() }
                .keyboardShortcut(.escape, modifiers: [])
            // Arrow keys move the single selection within the library grid.
            // No-op when the search field has focus (NSText consumes arrows
            // first to move the cursor) or when there's no current selection
            // — pressing arrows shouldn't yank the user into the grid out of
            // nowhere. Single-selection only; Shift-extend can come later.
            Button("") { navigateGrid(.left, scrollProxy: scrollProxy) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { navigateGrid(.right, scrollProxy: scrollProxy) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { navigateGrid(.up, scrollProxy: scrollProxy) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("") { navigateGrid(.down, scrollProxy: scrollProxy) }
                .keyboardShortcut(.downArrow, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private enum ArrowDirection { case up, down, left, right }

    private func navigateGrid(_ direction: ArrowDirection, scrollProxy: ScrollViewProxy) {
        guard !searchFocused else { return }
        let items = gridItems
        guard !items.isEmpty else { return }

        // Locate the current focus across both selection buckets. Source
        // selection wins when set (it's mutually exclusive with library
        // selection by construction). Falls back to library anchor → first
        // selected book → no-op.
        let currentIndex: Int? = {
            if let sourceID = selectedSourceID {
                return items.firstIndex { item in
                    if case .source(let r) = item { return r.id == sourceID }
                    return false
                }
            }
            let bookID = selectionAnchor ?? selectedBookIDs.first
            guard let bookID else { return nil }
            return items.firstIndex { item in
                if case .book(let b) = item { return b.id == bookID }
                return false
            }
        }()
        guard let currentIndex else { return }

        // List mode (search) is a single column; the grid's column count
        // doesn't refresh while the list is on screen, so use 1 explicitly.
        let columnsForNav = isSearching ? 1 : gridColumnCount
        let step: Int
        switch direction {
        case .left: step = isSearching ? 0 : -1
        case .right: step = isSearching ? 0 : 1
        case .up: step = -columnsForNav
        case .down: step = columnsForNav
        }
        let newIndex = max(0, min(items.count - 1, currentIndex + step))
        guard newIndex != currentIndex else { return }

        let target = items[newIndex]
        switch target {
        case .book(let book):
            handlePlainClick(book)
        case .source(let result):
            withAnimation(selectionAnimation) {
                selectedBookIDs = []
                selectionAnchor = nil
                selectedSourceID = result.id
                searchFocused = false
            }
        }
        withAnimation(selectionAnimation) {
            scrollProxy.scrollTo(target.id, anchor: .center)
        }
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
        if searchFocused {
            searchFocused = false
            return
        }
        if !searchText.isEmpty {
            searchText = ""
            return
        }
        if !selectedBookIDs.isEmpty {
            clearSelection()
            return
        }
        if inspectorOpen {
            inspectorOpen = false
            return
        }
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

struct GridColumnCountPreference: PreferenceKey {
    static let defaultValue: Int = 1
    static func reduce(value: inout Int, nextValue: () -> Int) {
        value = max(value, nextValue())
    }
}

/// Session-level delegate for a one-shot download. Owns:
///  - the destination URL (file is moved out of the per-task temp location
///    inside `didFinishDownloadingTo` because the temp file is removed
///    synchronously when that callback returns),
///  - the continuation that resumes the awaiting `fetchToTempFile`,
///  - the progress callback that drives the source-card capsule.
///
/// Used with a *custom* `URLSession` (not `.shared`) and a plain
/// `downloadTask(with:)` — Apple's completion-handler-based downloads
/// (including the `download(from:)` async wrapper) suppress
/// `URLSessionDownloadDelegate` data callbacks, so this is the only path
/// that actually delivers `didWriteData` updates.
///
/// Progress denominator preference:
/// 1. Server's `Content-Length` (`totalBytesExpectedToWrite > 0`).
/// 2. Plugin-declared `sizeBytes` (`fallbackExpectedBytes`) — common when
///    the CDN uses chunked transfer encoding and omits Content-Length.
/// 3. Neither — progress stays nil and the capsule shows "Downloading"
///    without a percentage.
private final class ProgressDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let fallbackExpectedBytes: Int64?
    let onTaskCreated: @MainActor @Sendable (URLSessionTask) -> Void
    let onProgress: @MainActor @Sendable (Double?) -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?

    init(
        destination: URL,
        fallbackExpectedBytes: Int64?,
        onTaskCreated: @MainActor @Sendable @escaping (URLSessionTask) -> Void,
        onProgress: @MainActor @Sendable @escaping (Double?) -> Void
    ) {
        self.destination = destination
        self.fallbackExpectedBytes = fallbackExpectedBytes
        self.onTaskCreated = onTaskCreated
        self.onProgress = onProgress
    }

    func setContinuation(_ c: CheckedContinuation<URL, Error>) {
        lock.lock()
        defer { lock.unlock() }
        continuation = c
    }

    /// Resumes the awaiting caller exactly once. Subsequent calls (e.g.
    /// `didCompleteWithError(nil)` after a successful `didFinishDownloadingTo`)
    /// are no-ops.
    private func consumeContinuation() -> CheckedContinuation<URL, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = continuation
        continuation = nil
        return c
    }

    // Fires the moment URLSession instantiates the task — before the first
    // byte arrives. Lets the caller register the task for cancellation so a
    // fast click on X is honored even if no progress callback has fired yet.
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        Task { @MainActor in onTaskCreated(task) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // NSURLSessionTransferSizeUnknown (-1) when Content-Length is missing.
        let denominator: Int64? = {
            if totalBytesExpectedToWrite > 0 { return totalBytesExpectedToWrite }
            if let f = fallbackExpectedBytes, f > 0 { return f }
            return nil
        }()
        // Clamp at 1.0 — a slightly-low plugin estimate (compressed-on-disk
        // size vs. wire bytes, etc.) shouldn't print "Downloading 103%".
        let progress: Double? = denominator.map { d in
            min(1.0, Double(totalBytesWritten) / Double(d))
        }
        Task { @MainActor in onProgress(progress) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move the file out of the per-task temp location *before* returning;
        // URLSession deletes `location` the moment this callback exits.
        do {
            if let http = downloadTask.response as? HTTPURLResponse,
                !(200..<300).contains(http.statusCode)
            {
                consumeContinuation()?.resume(throwing: URLError(.badServerResponse))
                return
            }
            try FileManager.default.moveItem(at: location, to: destination)
            consumeContinuation()?.resume(returning: destination)
        } catch {
            consumeContinuation()?.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success path: didFinishDownloadingTo already resumed the
        // continuation; consumeContinuation() returns nil here. Failure path
        // (including URLError.cancelled): resume with the error. Always
        // invalidate the session so the delegate is released.
        if let error {
            consumeContinuation()?.resume(throwing: error)
        }
        session.finishTasksAndInvalidate()
    }
}
