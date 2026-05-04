import SwiftUI

/// Left-edge floating pane: organisation and filtering. Same shape language
/// as the right inspector. Holds three sections:
///   - All Books (clears all axes)
///   - Collections (user-created, with create/rename/delete + drag-to-add)
///   - Languages (auto-populated from the books' locales)
struct LibrarySidebar: View {
    @Binding var selectedCollection: UUID?
    @Binding var selectedLanguage: String?
    let totalBooks: Int
    let collections: [Collection]
    let collectionCounts: [UUID: Int]
    let languageCounts: [String: Int]
    let onCreateCollection: (String) -> Void
    let onRenameCollection: (UUID, String) -> Void
    let onRequestDeleteCollection: (Collection) -> Void
    let onDropOnCollection: (BookDrag, UUID) -> Bool

    @State private var creatingCollection = false
    @State private var newCollectionName = ""
    @State private var renamingCollectionID: UUID?
    @State private var renameDraft = ""
    /// Collection currently under a hovering drag — gets an accent-tinted
    /// background to confirm it'll receive the drop.
    @State private var dropTargetedCollectionID: UUID?
    /// Collection that just received a drop — gets a brief accent flash so
    /// the user sees the items landed somewhere even though we don't navigate.
    @State private var recentlyDroppedCollectionID: UUID?
    @FocusState private var newCollectionFocused: Bool
    @FocusState private var renameFocused: Bool

    private var sortedLocales: [String] {
        languageCounts.keys.sorted()
    }

    var body: some View {
        Theme.panel
            .overlay {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        allBooksSection
                            // Clears the traffic lights — they sit at
                            // ~y=24-38 from window top after the inset; the
                            // sidebar pane starts at paneInset (8), so 48pt
                            // here puts the first row well below them.
                            .padding(.top, 48)

                        collectionsSection

                        if !sortedLocales.isEmpty {
                            languagesSection
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.menuInset)
                    // Reserve space at the bottom so content doesn't sit
                    // under the floating bottom-chrome toggle button.
                    .padding(.bottom, 64)
                }
            }
    }

    // MARK: - All Books

    private var allBooksSection: some View {
        VStack(spacing: 0) {
            row(
                label: "All Books",
                count: totalBooks,
                isSelected: selectedCollection == nil && selectedLanguage == nil
            ) {
                selectedCollection = nil
                selectedLanguage = nil
            }
        }
    }

    // MARK: - Collections

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                sectionHeader("Collections")
                Spacer()
                addCollectionButton
                    .padding(.trailing, Theme.Spacing.menuInset + Theme.Spacing.sm)
            }

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

    private var addCollectionButton: some View {
        Button {
            beginCreate()
        } label: {
            Icon(symbol: "plus", weight: .bold, size: 11)
                .foregroundStyle(.primary.opacity(0.55))
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
                    .foregroundStyle(.primary.opacity(isSelected ? 0.95 : 0.78))
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.45))
            }
        }
        .buttonStyle(SidebarRowStyle(
            isSelected: isSelected,
            isDropTargeted: isDropTargeted,
            recentlyDropped: recentlyDropped
        ))
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
        recentlyDroppedCollectionID = collectionID
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(550))
            if recentlyDroppedCollectionID == collectionID {
                recentlyDroppedCollectionID = nil
            }
        }
    }

    private var newCollectionField: some View {
        TextField("New collection", text: $newCollectionName)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .regular))
            .focused($newCollectionFocused)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sidebarRow, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .padding(.horizontal, Theme.Spacing.menuInset)
            .onSubmit { commitCreate() }
            .onAppear { newCollectionFocused = true }
            .onChange(of: newCollectionFocused) { _, focused in
                // Cancel-on-blur: if the user clicks away without naming the
                // collection, the inline field disappears with no side effect.
                if !focused {
                    if newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        cancelCreate()
                    } else {
                        commitCreate()
                    }
                }
            }
    }

    private func renameField(for collection: Collection) -> some View {
        TextField("", text: $renameDraft)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .regular))
            .focused($renameFocused)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sidebarRow, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .padding(.horizontal, Theme.Spacing.menuInset)
            .onSubmit { commitRename(collection) }
            .onAppear { renameFocused = true }
            .onChange(of: renameFocused) { _, focused in
                if !focused {
                    let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, trimmed != collection.name {
                        commitRename(collection)
                    } else {
                        cancelRename()
                    }
                }
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

    // MARK: - Languages

    private var languagesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Languages")

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

    /// Tiny vertical gap between row backgrounds — keeps hovers/selections
    /// from running flush into each other while staying visually tight.
    private static let rowSpacing: CGFloat = 2

    // MARK: - Building blocks

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary.opacity(0.55))
            .tracking(0.2)
            .textCase(.uppercase)
            .padding(.leading, Theme.Spacing.menuInset + Theme.Spacing.md)
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
                    .foregroundStyle(.primary.opacity(isSelected ? 0.95 : 0.78))
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.45))
            }
        }
        .buttonStyle(SidebarRowStyle(isSelected: isSelected))
    }
}

/// Sidebar row with persistent selection highlight (vs MenuRowStyle, which
/// only handles hover/press). Selection is sticky; hover is softer; press
/// is the strongest. Drop targeting and post-drop flash use the accent
/// colour to confirm the row received an in-flight drag.
private struct SidebarRowStyle: ButtonStyle {
    let isSelected: Bool
    var isDropTargeted: Bool = false
    var recentlyDropped: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        SidebarRowBody(
            configuration: configuration,
            isSelected: isSelected,
            isDropTargeted: isDropTargeted,
            recentlyDropped: recentlyDropped
        )
    }
}

private struct SidebarRowBody: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    let isDropTargeted: Bool
    let recentlyDropped: Bool
    @State private var hovered = false

    var body: some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sidebarRow, style: .continuous)
                    .fill(highlight)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sidebarRow, style: .continuous)
                    .fill(Color.primary.opacity(recentlyDropped ? 0.14 : 0))
                    .animation(.easeOut(duration: 0.45), value: recentlyDropped)
            )
            .padding(.horizontal, Theme.Spacing.menuInset)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }

    private var highlight: Color {
        // Drop-targeted is the strongest neutral fill; selection sits below
        // it; press + hover are progressively softer. All on .primary so
        // the colour stays neutral against accent-coloured content.
        if isDropTargeted { return Color.primary.opacity(0.18) }
        if isSelected { return Color.primary.opacity(0.10) }
        if configuration.isPressed { return Color.primary.opacity(0.08) }
        if hovered { return Color.primary.opacity(0.05) }
        return .clear
    }
}
