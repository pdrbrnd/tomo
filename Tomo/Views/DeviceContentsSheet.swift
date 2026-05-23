import AppKit
import SwiftUI

/// Sheet presented from the DeviceTile. Lists everything currently on the
/// connected device's documents folder, lets the user multi-select, search,
/// and delete in bulk. Mixes "matched" rows (filename resolves to a library
/// `Book` — show cover + title + author + "In Library" tag) and "orphan"
/// rows (file on device with no library match — filename + folder, dimmed).
///
/// Selection follows the library grid's native macOS pattern (cmd-click
/// toggles, shift-click extends a range). Cmd-A selects every visible row;
/// Delete triggers the destructive confirmation.
struct DeviceContentsSheet: View {
    let device: any BookDevice
    let books: [Book]
    let onDismiss: () -> Void
    let onDelete: ([String]) async -> Void

    @State private var rows: [Row] = []
    @State private var searchText = ""
    @State private var selection: Set<String> = []
    @State private var anchor: String?
    @State private var loading = true
    @State private var deleting = false
    @State private var confirmDelete = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            insetRule
            content
            insetRule
            footer
        }
        .frame(width: 720, height: 560)
        .background(keyboardShortcutBridge)
        .task(id: device.id) { await refresh() }
        .confirmationDialog(
            confirmDeleteTitle,
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete from \(device.displayName)", role: .destructive) {
                Task { await performDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the file from the device. Files in the library are unaffected.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.md) {
            Icon(symbol: "ipad", weight: .regular, size: 16)
                .foregroundStyle(.primary.opacity(Theme.Text.muted))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.system(size: 14, weight: .semibold))
                if let subtitle = deviceSubtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(Theme.Text.secondary))
                }
            }
            Spacer()
            searchField
            Button("Done") { onDismiss() }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.lg)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Icon(symbol: "magnifyingglass", weight: .regular, size: 12)
                .foregroundStyle(.primary.opacity(Theme.Text.secondary))
            TextField(
                "",
                text: $searchText,
                prompt: Text("Search").foregroundStyle(.primary.opacity(Theme.Text.placeholder))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(.primary.opacity(Theme.Text.primary))
            .focused($searchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Icon(symbol: "xmark.circle.fill", weight: .regular, size: 12)
                        .foregroundStyle(.primary.opacity(Theme.Text.tertiary))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .frame(width: 200, height: 28)
        .background(
            ZStack {
                Capsule(style: .continuous).fill(Theme.surface)
                Capsule(style: .continuous).stroke(Theme.hairline, lineWidth: 0.5)
            }
        )
        .contentShape(Capsule(style: .continuous))
        .onTapGesture { searchFocused = true }
    }

    private var deviceSubtitle: String? {
        if let kindle = device as? Kindle, let fw = kindle.firmwareVersion {
            return "Firmware \(fw)"
        }
        return nil
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if loading {
            centered { ProgressView().controlSize(.small) }
        } else if rows.isEmpty {
            centered {
                Text("Nothing on the device.")
                    .foregroundStyle(.secondary)
                Text("Drag a book onto the device chip to send it.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } else if visibleRows.isEmpty {
            centered {
                Text("No matches.")
                    .foregroundStyle(.secondary)
                Text("Try a different search.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(visibleRows) { row in
                        DeviceRowView(
                            row: row,
                            selected: selection.contains(row.id)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { handleTap(row: row) }
                        .contextMenu {
                            Button("Delete from \(device.displayName)…", role: .destructive) {
                                if !selection.contains(row.id) {
                                    selection = [row.id]
                                    anchor = row.id
                                }
                                confirmDelete = true
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
        }
    }

    private func centered<C: View>(@ViewBuilder content: () -> C) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(footerSummary)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(Theme.Text.secondary))
                .contentTransition(.numericText())
            Spacer()
            if deleting {
                ProgressView().controlSize(.small).padding(.trailing, Theme.Spacing.sm)
            }
            if !selection.isEmpty {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Text("Delete \(selection.count) from \(device.displayName)…")
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .tint(.red)
                .disabled(deleting)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.xl)
    }

    /// "N of M items · X.X GB" while searching, "M items · X.X GB" otherwise.
    /// Storage total reflects what's *visible*, not the whole device, so the
    /// footer reads as "what this view shows" not "what your device holds."
    private var footerSummary: String {
        let visible = visibleRows
        let filtered = !searchText.isEmpty
        let totalBytes = visible.reduce(into: Int64(0)) { $0 += $1.size }
        let sizeLabel = totalBytes.formatted(.byteCount(style: .file))
        let prefix = filtered ? "\(visible.count) of \(rows.count) items" : itemLabel(rows.count)
        return "\(prefix) · \(sizeLabel)"
    }

    private func itemLabel(_ n: Int) -> String {
        n == 1 ? "1 item" : "\(n) items"
    }

    private var confirmDeleteTitle: String {
        selection.count == 1
            ? "Delete this file from \(device.displayName)?"
            : "Delete \(selection.count) files from \(device.displayName)?"
    }

    // MARK: - Filtering

    /// Rows after applying the current search. Case-insensitive substring
    /// match across title, authors, filename, and on-device folder so the
    /// user can search by whatever they remember.
    private var visibleRows: [Row] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { row in
            if row.file.name.lowercased().contains(needle) { return true }
            if let folder = row.file.folder, folder.lowercased().contains(needle) { return true }
            if let book = row.book {
                if book.title.lowercased().contains(needle) { return true }
                if book.authors.contains(where: { $0.lowercased().contains(needle) }) { return true }
            }
            return false
        }
    }

    // MARK: - Selection

    /// Native macOS selection semantics:
    /// - plain click selects exactly the row + sets anchor
    /// - cmd-click toggles the row in the selection (anchor unchanged)
    /// - shift-click extends from anchor to the clicked row
    ///
    /// Shift-range walks the *visible* list (post-filter), not the underlying
    /// rows, so dragging a range while searching doesn't sneak in hidden rows.
    private func handleTap(row: Row) {
        let flags = NSEvent.modifierFlags
        let visible = visibleRows
        if flags.contains(.shift), let anchorID = anchor,
            let a = visible.firstIndex(where: { $0.id == anchorID }),
            let b = visible.firstIndex(where: { $0.id == row.id })
        {
            let range = a <= b ? a...b : b...a
            selection = Set(visible[range].map(\.id))
        } else if flags.contains(.command) {
            if selection.contains(row.id) {
                selection.remove(row.id)
            } else {
                selection.insert(row.id)
            }
            anchor = row.id
        } else {
            selection = [row.id]
            anchor = row.id
        }
    }

    // MARK: - Keyboard

    /// Hidden bridge that hosts ⌘A (select all visible) and ⌫ (delete).
    /// Lives inside the sheet so the shortcuts only fire while the sheet is
    /// up. Each guard checks `searchFocused` so typing in the search field
    /// doesn't trigger select-all / delete.
    private var keyboardShortcutBridge: some View {
        ZStack {
            Button("") { handleSelectAll() }
                .keyboardShortcut("a", modifiers: .command)
            Button("") { handleDelete() }
                .keyboardShortcut(.delete, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func handleSelectAll() {
        guard !searchFocused else { return }
        selection = Set(visibleRows.map(\.id))
        anchor = visibleRows.last?.id
    }

    private func handleDelete() {
        guard !searchFocused, !selection.isEmpty, !deleting else { return }
        confirmDelete = true
    }

    // MARK: - Data

    private func refresh() async {
        loading = true
        let files = await Task.detached { device.files() }.value
        // `uniquingKeysWith` guards against the theoretical case where two
        // library books compute the same on-device filename. `bookFileSlug`
        // is unique by design today, so the merge function never fires;
        // the safer dict initialiser just avoids a latent crash.
        let bookByDeviceName = Dictionary(
            books.map { (device.deviceFilename(for: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Sort: most recently modified first — matches how users think
        // about "what did I send last."
        let sorted = files.sorted { $0.modifiedAt > $1.modifiedAt }
        rows = sorted.map { file in
            Row(file: file, book: bookByDeviceName[file.name])
        }
        // Prune selection to only what still exists on device.
        let surviving = Set(rows.map(\.id))
        selection = selection.intersection(surviving)
        loading = false
    }

    private func performDelete() async {
        let paths = Array(selection)
        deleting = true
        defer { deleting = false }
        await onDelete(paths)
        selection = []
        anchor = nil
        await refresh()
    }

    // MARK: - Row

    struct Row: Identifiable {
        let file: DeviceFile
        let book: Book?

        /// Stable id is the relative path so two files with the same basename
        /// in different on-device folders don't collide in selection / ForEach.
        var id: String { file.relativePath }
        var size: Int64 { file.size }
    }

    private var insetRule: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
    }
}

// MARK: - Row view

private struct DeviceRowView: View {
    let row: DeviceContentsSheet.Row
    let selected: Bool

    @State private var hovered = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            cover
            VStack(alignment: .leading, spacing: 3) {
                Text(primaryLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(isOrphan ? Theme.Text.muted : Theme.Text.primary))
                    .lineLimit(1)
                if let secondary = secondaryLabel {
                    Text(secondary)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(Theme.Text.secondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Spacing.md)
            if let tag = matchTag {
                MatchTagView(tag: tag)
            }
            Text(row.file.size.formatted(.byteCount(style: .file)))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(Theme.Text.tertiary))
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.menuItem, style: .continuous)
                .fill(rowBackground)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.menuItem, style: .continuous))
        .onHover { hovered = $0 }
    }

    private var isOrphan: Bool { row.book == nil }

    private var primaryLabel: String {
        row.book?.title ?? row.file.name
    }

    /// "Authors · Folder" / "Authors" / "Folder" / nil
    /// — orphans drop the "Not in library" text since the missing cover +
    /// the absence of the In Library tag already signal the match state.
    private var secondaryLabel: String? {
        var parts: [String] = []
        if let book = row.book, !book.authors.isEmpty {
            parts.append(book.authors.joined(separator: ", "))
        }
        if let folder = row.file.folder {
            parts.append(folder)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Today: only `.exact` when the on-device filename slug matches a
    /// library book's `deviceFilename(for:)`. The `.similar` case is the
    /// hook for the future metadata-based matcher — different label so the
    /// two confidence levels read differently.
    private var matchTag: MatchTag? {
        row.book != nil ? .exact : nil
    }

    @ViewBuilder
    private var cover: some View {
        let width: CGFloat = 32
        let height = width * Theme.Library.bookHeightMultiplier
        Group {
            if let book = row.book {
                LocalCoverImage(
                    url: book.coverURL,
                    fallbackTitle: book.title,
                    fallbackAuthor: book.authors.first
                )
            } else {
                ZStack {
                    Theme.surface
                    Icon(symbol: "doc", weight: .regular, size: 14)
                        .foregroundStyle(.primary.opacity(Theme.Text.tertiary))
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 0.5)
        )
        .opacity(isOrphan ? 0.55 : 1.0)
    }

    private var rowBackground: Color {
        if selected { return .primary.opacity(Theme.Surface.selected) }
        if hovered { return .primary.opacity(Theme.Surface.hover) }
        return .clear
    }
}

// MARK: - Match tag

/// Status badge shown on rows whose on-device file maps to a library book.
/// `.exact` fires today (filename slug match); `.similar` is wired for a
/// future metadata-based matcher and rendered with an outlined treatment
/// so the two levels of confidence read distinctly without a colour.
private enum MatchTag {
    case exact
    case similar

    var label: String {
        switch self {
        case .exact: "In Library"
        case .similar: "Same book in Library"
        }
    }
}

private struct MatchTagView: View {
    let tag: MatchTag

    var body: some View {
        Text(tag.label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.primary.opacity(Theme.Text.muted))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background)
            .overlay(border)
    }

    @ViewBuilder
    private var background: some View {
        switch tag {
        case .exact:
            Capsule(style: .continuous).fill(.primary.opacity(0.08))
        case .similar:
            Capsule(style: .continuous).fill(.clear)
        }
    }

    @ViewBuilder
    private var border: some View {
        switch tag {
        case .exact:
            EmptyView()
        case .similar:
            Capsule(style: .continuous).stroke(Theme.hairline, lineWidth: 0.5)
        }
    }
}
