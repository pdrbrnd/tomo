import SwiftUI

/// Cross-cutting filter on the connected-device axis. Composable with
/// collection + language filters via AND, like every other axis.
enum DeviceFilter: String, Hashable {
    case onDevice
    case notOnDevice
}

/// Left-edge floating pane: organisation and filtering. Same shape language
/// as the right inspector. Sections:
///   - All Books (clears all axes)
///   - Device (only when a device is connected)
///   - Collections (user-created, with create/rename/delete + drag-to-add)
///   - Languages (auto-populated from the books' locales)
struct LibrarySidebar: View {
    @Binding var selectedCollection: UUID?
    @Binding var selectedLanguage: String?
    @Binding var selectedAuthor: String?
    @Binding var selectedDeviceFilter: DeviceFilter?
    let totalBooks: Int
    let collections: [Collection]
    let collectionCounts: [UUID: Int]
    let languageCounts: [String: Int]
    let authorCounts: [String: Int]
    let deviceConnected: Bool
    let onDeviceCount: Int
    let notOnDeviceCount: Int
    /// Bumped by `LibraryView` when the user picks File → New Collection
    /// from the menu bar. Drives the same inline-create field as the `+`
    /// button so the menu path doesn't need a separate dialog.
    let newCollectionTrigger: UUID
    let onCreateCollection: (String) -> Void
    let onRenameCollection: (UUID, String) -> Void
    let onRequestDeleteCollection: (Collection) -> Void
    let onDropOnCollection: (BookDrag, UUID) -> Bool

    @State private var creatingCollection = false
    @State private var newCollectionName = ""
    @State private var renamingCollectionID: UUID?
    @State private var renameDraft = ""
    /// Section ids the user has collapsed in the sidebar. Persisted across
    /// launches via `@AppStorage`. Encoded as a comma-joined string — small
    /// stable set of ids, plain Codable buys nothing here.
    @AppStorage("sidebar.collapsedSections") private var collapsedRaw: String = ""
    /// Collection currently under a hovering drag — gets an accent-tinted
    /// background to confirm it'll receive the drop.
    @State private var dropTargetedCollectionID: UUID?
    /// Collection that just received a drop — gets a brief accent flash so
    /// the user sees the items landed somewhere even though we don't navigate.
    @State private var recentlyDroppedCollectionID: UUID?
    /// Tracks the in-flight clear-flash task so a second drop on the same
    /// row resets the timer instead of letting the first task race in and
    /// clear the new flash early.
    @State private var flashClearTask: Task<Void, Never>?
    @FocusState private var focusedField: SidebarFocus?

    private enum SidebarFocus: Hashable {
        case newCollection
        case rename
    }

    private var sortedLocales: [String] {
        // Sort by the localized display name so the user sees an
        // alphabetical list of language names ("English", "German",
        // "Portuguese") rather than alphabetised codes ("de", "en", "pt").
        languageCounts.keys.sorted { lhs, rhs in
            let lname = Locale.current.localizedString(forIdentifier: lhs) ?? lhs
            let rname = Locale.current.localizedString(forIdentifier: rhs) ?? rhs
            return lname.localizedCaseInsensitiveCompare(rname) == .orderedAscending
        }
    }

    private var sortedAuthors: [String] {
        authorCounts.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var collapsedSections: Set<String> {
        Set(collapsedRaw.split(separator: ",").map(String.init))
    }

    private func isCollapsed(_ id: String) -> Bool {
        collapsedSections.contains(id)
    }

    private func toggleCollapsed(_ id: String) {
        var current = collapsedSections
        if current.contains(id) {
            current.remove(id)
        } else {
            current.insert(id)
        }
        collapsedRaw = current.sorted().joined(separator: ",")
    }

    private enum SectionID {
        static let device = "device"
        static let collections = "collections"
        static let languages = "languages"
        static let authors = "authors"
    }

    var body: some View {
        Theme.panel
            .overlay {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        allBooksSection
                            .padding(.top, Theme.Chrome.paneTopReserve)

                        if deviceConnected {
                            deviceSection
                        }

                        collectionsSection

                        if !sortedAuthors.isEmpty {
                            authorsSection
                        }

                        if !sortedLocales.isEmpty {
                            languagesSection
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.menuInset)
                    .padding(.bottom, Theme.Chrome.paneBottomReserve)
                }
            }
            .onChange(of: newCollectionTrigger) { _, _ in
                beginCreate()
                focusedField = .newCollection
            }
    }

    // MARK: - All Books

    private var allBooksSection: some View {
        VStack(spacing: 0) {
            row(
                label: "All Books",
                count: totalBooks,
                isSelected: selectedCollection == nil
                    && selectedLanguage == nil
                    && selectedAuthor == nil
                    && selectedDeviceFilter == nil
            ) {
                selectedCollection = nil
                selectedLanguage = nil
                selectedAuthor = nil
                selectedDeviceFilter = nil
            }
        }
    }

    // MARK: - Device

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarSectionHeader("Device", id: SectionID.device)

            if !isCollapsed(SectionID.device) {
                VStack(spacing: Self.rowSpacing) {
                    row(
                        label: "On device",
                        count: onDeviceCount,
                        isSelected: selectedDeviceFilter == .onDevice
                    ) {
                        selectedDeviceFilter = (selectedDeviceFilter == .onDevice) ? nil : .onDevice
                    }
                    row(
                        label: "Not on device",
                        count: notOnDeviceCount,
                        isSelected: selectedDeviceFilter == .notOnDevice
                    ) {
                        selectedDeviceFilter = (selectedDeviceFilter == .notOnDevice) ? nil : .notOnDevice
                    }
                }
            }
        }
    }

    // MARK: - Collections

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarSectionHeader("Collections", id: SectionID.collections) {
                addCollectionButton
            }

            if !isCollapsed(SectionID.collections) {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(collections) { collection in
                        if renamingCollectionID == collection.id {
                            renameField(for: collection)
                        } else {
                            collectionRow(collection)
                        }
                    }

                    if creatingCollection {
                        newCollectionField
                    }
                }
            }
        }
    }

    private var addCollectionButton: some View {
        Button {
            beginCreate()
        } label: {
            Icon(symbol: "plus", weight: .medium, size: 11)
                .foregroundStyle(.primary.opacity(Theme.Text.secondary))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New collection")
    }

    private func collectionRow(_ collection: Collection) -> some View {
        let count = collectionCounts[collection.id] ?? 0
        let isSelected = selectedCollection == collection.id
        let isDropTargeted = dropTargetedCollectionID == collection.id
        let recentlyDropped = recentlyDroppedCollectionID == collection.id
        return Button {
            selectedCollection = isSelected ? nil : collection.id
        } label: {
            HStack {
                Text(collection.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary.opacity(isSelected ? Theme.Text.emphatic : Theme.Text.muted))
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.primary.opacity(Theme.Text.tertiary))
            }
        }
        .buttonStyle(
            SidebarRowStyle(
                isSelected: isSelected,
                isDropTargeted: isDropTargeted,
                recentlyDropped: recentlyDropped
            )
        )
        .contextMenu {
            Button("Rename…") { beginRename(collection) }
            Button("Delete…", role: .destructive) {
                onRequestDeleteCollection(collection)
            }
        }
        .dropDestination(for: BookDrag.self) { drags, _ in
            let allIDs = drags.flatMap(\.bookIDs)
            guard !allIDs.isEmpty else { return false }
            let accepted = onDropOnCollection(BookDrag(bookIDs: allIDs), collection.id)
            if accepted { flashRecentDrop(on: collection.id) }
            return accepted
        } isTargeted: { targeted in
            dropTargetedCollectionID = targeted ? collection.id : nil
        }
    }

    private func flashRecentDrop(on collectionID: UUID) {
        // Cancel any in-flight clear so a second drop in quick succession
        // resets the timer rather than getting cleared early by the first
        // task.
        flashClearTask?.cancel()
        recentlyDroppedCollectionID = collectionID
        flashClearTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }
            recentlyDroppedCollectionID = nil
        }
    }

    private var newCollectionField: some View {
        inlineTextField(
            text: $newCollectionName,
            placeholder: "New collection",
            field: .newCollection,
            onSubmit: { commitCreate() },
            onBlur: {
                // Cancel-on-blur: if the user clicks away without naming the
                // collection, the inline field disappears with no side effect.
                if newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    cancelCreate()
                } else {
                    commitCreate()
                }
            }
        )
    }

    private func renameField(for collection: Collection) -> some View {
        inlineTextField(
            text: $renameDraft,
            placeholder: "",
            field: .rename,
            onSubmit: { commitRename(collection) },
            onBlur: {
                let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed != collection.name {
                    commitRename(collection)
                } else {
                    cancelRename()
                }
            }
        )
    }

    private func inlineTextField(
        text: Binding<String>,
        placeholder: String,
        field: SidebarFocus,
        onSubmit: @escaping () -> Void,
        onBlur: @escaping () -> Void
    ) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .regular))
            .focused($focusedField, equals: field)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sidebarRow, style: .continuous)
                    .fill(.primary.opacity(Theme.Surface.hoverSoft))
            )
            .padding(.horizontal, Theme.Spacing.menuInset)
            .onSubmit(onSubmit)
            .onAppear { focusedField = field }
            .onChange(of: focusedField) { _, newFocus in
                if newFocus != field { onBlur() }
            }
    }

    private func beginCreate() {
        creatingCollection = true
        newCollectionName = ""
        // Cancel any in-flight rename.
        renamingCollectionID = nil
    }

    private func commitCreate() {
        let trimmed = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            creatingCollection = false
            newCollectionName = ""
        }
        guard !trimmed.isEmpty else { return }
        onCreateCollection(trimmed)
    }

    private func cancelCreate() {
        creatingCollection = false
        newCollectionName = ""
    }

    private func beginRename(_ collection: Collection) {
        renamingCollectionID = collection.id
        renameDraft = collection.name
        creatingCollection = false
    }

    private func commitRename(_ collection: Collection) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            renamingCollectionID = nil
            renameDraft = ""
        }
        guard !trimmed.isEmpty, trimmed != collection.name else { return }
        onRenameCollection(collection.id, trimmed)
    }

    private func cancelRename() {
        renamingCollectionID = nil
        renameDraft = ""
    }

    // MARK: - Authors

    private var authorsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarSectionHeader("Authors", id: SectionID.authors)

            if !isCollapsed(SectionID.authors) {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(sortedAuthors, id: \.self) { author in
                        row(
                            label: author,
                            count: authorCounts[author] ?? 0,
                            isSelected: selectedAuthor == author
                        ) {
                            selectedAuthor = (selectedAuthor == author) ? nil : author
                        }
                    }
                }
            }
        }
    }

    // MARK: - Languages

    private var languagesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarSectionHeader("Languages", id: SectionID.languages)

            if !isCollapsed(SectionID.languages) {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(sortedLocales, id: \.self) { tag in
                        let display = Locale.current.localizedString(forIdentifier: tag) ?? tag
                        row(
                            label: display,
                            count: languageCounts[tag] ?? 0,
                            isSelected: selectedLanguage == tag
                        ) {
                            selectedLanguage = (selectedLanguage == tag) ? nil : tag
                        }
                    }
                }
            }
        }
    }

    /// Tiny vertical gap between row backgrounds — keeps hovers/selections
    /// from running flush into each other while staying visually tight.
    private static let rowSpacing: CGFloat = 2

    // MARK: - Building blocks

    private func sidebarSectionHeader(_ title: String, id: String) -> some View {
        SectionHeader(
            title: title,
            isCollapsed: isCollapsed(id),
            onToggle: { toggleCollapsed(id) }
        )
        .padding(.leading, Theme.Spacing.menuInset + Theme.Spacing.md)
        .padding(.trailing, Theme.Spacing.menuInset + Theme.Spacing.sm)
        .padding(.top, Theme.Spacing.xs)
        .padding(.bottom, Theme.Spacing.sm)
    }

    private func sidebarSectionHeader<Trailing: View>(
        _ title: String,
        id: String,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) -> some View {
        SectionHeader(
            title: title,
            isCollapsed: isCollapsed(id),
            onToggle: { toggleCollapsed(id) },
            trailing: trailing
        )
        .padding(.leading, Theme.Spacing.menuInset + Theme.Spacing.md)
        .padding(.trailing, Theme.Spacing.menuInset + Theme.Spacing.sm)
        .padding(.top, Theme.Spacing.xs)
        .padding(.bottom, Theme.Spacing.sm)
    }

    private func row(
        label: String,
        count: Int,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary.opacity(isSelected ? Theme.Text.emphatic : Theme.Text.muted))
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.primary.opacity(Theme.Text.tertiary))
            }
        }
        .buttonStyle(SidebarRowStyle(isSelected: isSelected))
    }
}
