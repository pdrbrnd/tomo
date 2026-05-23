import AppKit
import SwiftUI

/// Inspector that presents a single book and exposes actions as callbacks.
///
/// Doesn't reach into `AppState` directly — the parent owns the state and
/// passes in already-resolved data + actions. The editing affordances are
/// inline (no separate edit window): hover-pencil for text fields, Picker
/// for locale, drop/paste/right-click for cover.
///
/// The window-level bottom chrome handles closing — this view doesn't carry
/// its own close button.
struct BookInspector: View {
    let book: Book?
    let device: DeviceContext?
    /// Selected books when the parent has more than one book selected.
    var multiBooks: [Book]? = nil
    var multiDeviceInfo: MultiDeviceInfo? = nil

    /// When set, the inspector renders a source-result variant — same layout,
    /// read-only rows, "Download to library" action. Takes precedence over
    /// `book` and `multiBooks` when present.
    var sourceResult: PluginResult? = nil
    var sourceDownloadState: CardDownloadState = .idle
    var sourcePluginName: String? = nil
    /// Idle-state label for the source download action. Carries the active
    /// collection name when one is selected ("Download to Existential"); the
    /// caller composes the string so the inspector stays presentational.
    var sourceDownloadIdleTitle: String = "Download to library"
    var onSourceDownload: () -> Void = {}
    /// Called when the user clicks the action row while a download is in
    /// flight. Cancels the underlying `URLSessionTask`; the resulting
    /// `URLError.cancelled` collapses the inspector row back to idle without
    /// surfacing as an error.
    var onSourceCancel: () -> Void = {}

    /// Variant profiles available in the locale menu (e.g. pt-PT, en-GB).
    /// All bundled profiles, regardless of enable state — manual selection
    /// is unconstrained by the auto-detect toggle. Plain data, OK to pass in.
    let profiles: [LanguageProfile]
    /// Every collection in the library. Used to render chips for the
    /// book's memberships and to populate the "add to collection" popover.
    let allCollections: [Collection]

    let onUpdate: (Book) -> Void
    /// Runs the classifier on the inspector's book. Returns the classifier
    /// result (or nil if classification fails). The inspector applies the
    /// result via `onUpdate`.
    let onClassify: () async -> Classification?
    let onSetCoverFromFile: (URL) -> Void
    let onSetCoverFromImage: (NSImage) -> Void
    let onRemoveCover: () -> Void
    let onChooseFromOpenLibrary: () -> Void
    let onAddToCollection: (UUID) -> Void
    let onRemoveFromCollection: (UUID) -> Void
    let onCreateCollectionAndAdd: (String) -> Void
    let onShowInFinder: () -> Void
    let onSendToDevice: () -> Void
    let onRequestDelete: () -> Void
    let onSendMultiToDevice: () -> Void
    let onRequestDeleteMulti: () -> Void

    /// Pre-resolved device context.
    struct DeviceContext {
        let displayName: String
        let isOnDevice: Bool
        let canSend: Bool
    }

    /// Pre-resolved multi-selection device context. `sendableCount` is
    /// the subset of `multiBooks` the device can accept.
    struct MultiDeviceInfo {
        let displayName: String
        let sendableCount: Int
    }

    /// Transient confidence read-out shown beneath the locale picker after
    /// auto-detect. Cleared after a few seconds — confidence isn't persisted.
    @State private var transientClassification: Classification?
    @State private var classifyingTask: Task<Void, Never>?
    @State private var clearConfidenceTask: Task<Void, Never>?

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            Theme.panel

            if let sourceResult {
                sourceContent(for: sourceResult)
            } else if let book {
                content(for: book)
            } else if let multiBooks, !multiBooks.isEmpty {
                multiContent(books: multiBooks)
            } else {
                emptyState
            }
        }
        // Snap-replace on book change — the FlowLayout in the collections
        // section otherwise animates chips (and the `Add` chip) into their
        // new positions, which reads as the inspector "morphing" rather
        // than switching books.
        .transaction(value: book?.id) { $0.animation = nil }
        .onChange(of: book?.id) { _, _ in
            classifyingTask?.cancel()
            clearConfidenceTask?.cancel()
            transientClassification = nil
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("Select a book")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary.opacity(Theme.Text.placeholder))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func multiContent(books: [Book]) -> some View {
        ScrollView {
            VStack(alignment: .center, spacing: 0) {
                BookDragPreview(books: books)
                    .padding(.top, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.lg)

                Text("\(books.count) books selected")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.bottom, Theme.Spacing.xl)

                multiActions(books: books)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.bottom, Theme.Chrome.paneBottomReserve)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func multiActions(books: [Book]) -> some View {
        VStack(spacing: 0) {
            if let info = multiDeviceInfo, info.sendableCount > 0 {
                Button(action: onSendMultiToDevice) {
                    actionLabel(
                        icon: "ipad",
                        title: "Send \(info.sendableCount) to \(info.displayName)"
                    )
                }
            }
            ShareLink(items: books.map(\.fileURL)) {
                actionLabel(icon: "square.and.arrow.up", title: "Share \(books.count)…")
            }
            Button(role: .destructive, action: onRequestDeleteMulti) {
                actionLabel(icon: "trash", title: "Move \(books.count) to Trash…")
            }
        }
        .buttonStyle(MenuRowStyle())
    }

    @ViewBuilder
    private func content(for book: Book) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                coverHeader(for: book)
                    .padding(.top, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.xl)

                bibliographicSection(for: book)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.lg)

                metadataSection(for: book)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.xl)

                collectionsSection(for: book)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.xl)

                actions(for: book)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.bottom, Theme.Chrome.paneBottomReserve)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Centered cover at the top — the visual anchor for the inspector.
    /// Title/authors/year are pushed down into the metaRow table so the
    /// cover gets the full prominence at the top of the panel.
    private func coverHeader(for book: Book) -> some View {
        HStack {
            Spacer()
            InspectorCover(
                book: book,
                onSetCoverFromFile: onSetCoverFromFile,
                onSetCoverFromImage: onSetCoverFromImage,
                onRemoveCover: onRemoveCover,
                onChooseFromOpenLibrary: onChooseFromOpenLibrary
            )
            Spacer()
        }
    }

    /// Bibliographic section: title, authors, year. Same metaRow visual
    /// treatment as the standard metadata below, but conceptually a
    /// distinct group (the things describing the work itself, vs. file /
    /// origin / state metadata).
    private func bibliographicSection(for book: Book) -> some View {
        VStack(spacing: 0) {
            editableRow(label: "Title") {
                InlineEditField(
                    value: book.title,
                    placeholder: "Title",
                    font: .system(size: 12, weight: .regular),
                    color: .primary.opacity(0.92),
                    onCommit: { newValue in
                        guard !newValue.isEmpty else { return }
                        var updated = book
                        updated.title = newValue
                        onUpdate(updated)
                    }
                )
            }

            editableRow(label: "Authors") {
                InlineEditField(
                    value: book.authors.joined(separator: ", "),
                    placeholder: "Authors",
                    font: .system(size: 12, weight: .regular),
                    color: .primary.opacity(0.92),
                    onCommit: { newValue in
                        let parsed =
                            newValue
                            .split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        var updated = book
                        updated.authors = parsed
                        onUpdate(updated)
                    }
                )
            }

            editableRow(label: "Year") {
                InlineEditField(
                    value: book.year.map(String.init) ?? "",
                    placeholder: "—",
                    font: .system(size: 12, weight: .regular),
                    color: .primary.opacity(0.92),
                    onCommit: { newValue in
                        var updated = book
                        updated.year = Int(newValue.trimmingCharacters(in: .whitespacesAndNewlines))
                        onUpdate(updated)
                    }
                )
            }
        }
    }

    /// Standard (non-editable, except language) metadata.
    @ViewBuilder
    private func metadataSection(for book: Book) -> some View {
        VStack(spacing: 0) {
            languageRow(for: book)
            metaRow("Format", value: book.fileURL.pathExtension.uppercased())
            metaRow("Added", value: book.dateAdded.formatted(.dateTime.year().month(.abbreviated).day()))
            metaRow("Origin", value: originLabel(for: book))
        }
    }

    private func languageRow(for book: Book) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                rowLabel("Language")

                localePicker(for: book)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, Theme.Spacing.sm)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 0.5)
            }

            if let result = transientClassification {
                let display = Locale.current.localizedString(forIdentifier: result.profileId) ?? result.profileId
                let pct = Int((result.confidence * 100).rounded())
                HStack(alignment: .firstTextBaseline) {
                    rowLabel("")
                    Text("Detected: \(display) · \(pct)% confidence")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: transientClassification)
    }

    private func localePicker(for book: Book) -> some View {
        Menu {
            Button("Auto-detect from text") { runAutoDetect(for: book) }
            Divider()
            Picker("Language", selection: localeBinding(for: book)) {
                Text(Locale.current.localizedString(forIdentifier: "und") ?? "Unknown").tag("und")
                ForEach(localeOptions(currentLocale: book.locale)) { option in
                    Text(option.displayName).tag(option.id)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Language settings…") {
                openWindow(id: TomoApp.settingsWindowID)
            }
        } label: {
            Text(menuLabel(for: book.locale))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func localeBinding(for book: Book) -> Binding<String> {
        Binding(
            get: { book.locale },
            set: { newValue in
                guard newValue != book.locale else { return }
                var updated = book
                updated.locale = newValue
                onUpdate(updated)
            }
        )
    }

    private func menuLabel(for locale: String) -> String {
        if locale.isEmpty || locale == "und" {
            return Locale.current.localizedString(forIdentifier: "und") ?? "Unknown"
        }
        return Locale.current.localizedString(forIdentifier: locale) ?? locale
    }

    /// Builds the locale option list for the picker: every bundled variant
    /// profile plus every ISO 639-1 base language, plus the current value as
    /// a fallback if it isn't already in either set (e.g. an obscure tag).
    /// Sorted by localized display name so variants land next to their base
    /// (e.g. "Portuguese", "Portuguese (Brazil)", "Portuguese (Portugal)").
    private func localeOptions(currentLocale: String) -> [LocaleOption] {
        var seen: Set<String> = ["und"]
        var options: [LocaleOption] = []

        for profile in profiles where !seen.contains(profile.id) {
            seen.insert(profile.id)
            options.append(LocaleOption(id: profile.id, displayName: profile.displayName))
        }

        for code in Locale.LanguageCode.isoLanguageCodes {
            let id = code.identifier
            // ISO 639-1 only (2-letter codes). The full set runs into thousands
            // of esoteric codes; the picker is for humans.
            guard id.count == 2, !seen.contains(id) else { continue }
            guard let name = Locale.current.localizedString(forIdentifier: id) else { continue }
            seen.insert(id)
            options.append(LocaleOption(id: id, displayName: name))
        }

        if !currentLocale.isEmpty, currentLocale != "und", !seen.contains(currentLocale) {
            let baseName = Locale.current.localizedString(forIdentifier: currentLocale) ?? currentLocale
            options.append(LocaleOption(id: currentLocale, displayName: "\(baseName) (declared)"))
        }

        return options.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private struct LocaleOption: Identifiable, Hashable {
        let id: String
        let displayName: String
    }

    private func runAutoDetect(for book: Book) {
        classifyingTask?.cancel()
        clearConfidenceTask?.cancel()
        let bookID = book.id
        classifyingTask = Task { @MainActor in
            let result = await onClassify()
            // Cancellation can have arrived during the await; check
            // explicitly before applying state. (Same-book guard below
            // covers a related case but doesn't see the new task that
            // cancelled this one.)
            guard !Task.isCancelled else { return }
            guard let currentID = self.book?.id, currentID == bookID else { return }
            guard let result else { return }
            transientClassification = result
            var updated = book
            updated.locale = result.profileId
            onUpdate(updated)
            clearConfidenceTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                transientClassification = nil
            }
        }
    }

    // MARK: - Collections

    @ViewBuilder
    private func collectionsSection(for book: Book) -> some View {
        let memberships = allCollections.filter { book.collectionIDs.contains($0.id) }
        let available = allCollections.filter { !book.collectionIDs.contains($0.id) }

        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Collections")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary.opacity(Theme.Text.secondary))
                .tracking(0.2)
                .textCase(.uppercase)

            FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(memberships) { collection in
                    CollectionChip(name: collection.name) {
                        onRemoveFromCollection(collection.id)
                    }
                }
                AddCollectionChip(
                    available: available,
                    onAdd: onAddToCollection,
                    onCreateAndAdd: onCreateCollectionAndAdd
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One row in a metaRow-styled section, with an editable value column
    /// (caller supplies the editor view).
    private func editableRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            rowLabel(label)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Theme.Spacing.sm)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 0.5)
        }
    }

    private func metaRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            rowLabel(label)
            Text(value)
                .font(.system(size: 12, weight: .regular, design: monospaced ? .monospaced : .default))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Theme.Spacing.sm)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 0.5)
        }
    }

    private func rowLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.primary.opacity(Theme.Text.placeholder))
            .frame(width: 76, alignment: .leading)
    }

    @ViewBuilder
    private func actions(for book: Book) -> some View {
        VStack(spacing: 0) {
            if let device, device.canSend {
                Button(action: onSendToDevice) {
                    actionLabel(
                        icon: device.isOnDevice ? "arrow.clockwise" : "ipad",
                        title: device.isOnDevice
                            ? "Update on \(device.displayName)"
                            : "Send to \(device.displayName)"
                    )
                }
            }
            Button(action: onShowInFinder) {
                actionLabel(icon: "folder", title: "Show in Finder")
            }
            ShareLink(item: book.fileURL) {
                actionLabel(icon: "square.and.arrow.up", title: "Share…")
            }
            Button(role: .destructive, action: onRequestDelete) {
                actionLabel(icon: "trash", title: "Move to Trash…")
            }
        }
        .buttonStyle(MenuRowStyle())
    }

    private func actionLabel(icon: String, title: String) -> some View {
        HStack(spacing: 9) {
            Icon(symbol: icon, weight: .regular, size: 13)
                .frame(width: 14)
            Text(title)
        }
    }

    private func originLabel(for book: Book) -> String {
        switch book.origin {
        case .manualImport: "Manual import"
        case .source(let id, _): "Source: \(id)"
        }
    }

    // MARK: - Source mode

    @ViewBuilder
    private func sourceContent(for result: PluginResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sourceCoverHeader(for: result)
                    .padding(.top, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.xl)

                sourceBibliographicSection(for: result)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.lg)

                sourceMetadataSection(for: result)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.xl)

                sourceActions(for: result)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.bottom, Theme.Chrome.paneBottomReserve)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func sourceCoverHeader(for result: PluginResult) -> some View {
        HStack {
            Spacer()
            LocalCoverImage(
                url: result.coverURL,
                fallbackTitle: result.title,
                fallbackAuthor: result.authors.first
            )
            .aspectRatio(1 / Theme.Library.bookHeightMultiplier, contentMode: .fit)
            .frame(width: 160, height: 160 * Theme.Library.bookHeightMultiplier)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 0.5)
            )
            .softShadow(elevated: false)
            Spacer()
        }
    }

    /// Same row treatment as `bibliographicSection(for:)` but read-only —
    /// source results aren't editable. Visual parity is the goal so the
    /// inspector reads as one consistent component, not two.
    private func sourceBibliographicSection(for result: PluginResult) -> some View {
        VStack(spacing: 0) {
            metaRow("Title", value: result.title)
            metaRow("Authors", value: result.authors.isEmpty ? "—" : result.authors.joined(separator: ", "))
            metaRow("Year", value: result.year.map(String.init) ?? "—")
        }
    }

    @ViewBuilder
    private func sourceMetadataSection(for result: PluginResult) -> some View {
        VStack(spacing: 0) {
            metaRow("Format", value: result.format.uppercased())
            if !result.language.isEmpty {
                let display = Locale.current.localizedString(forIdentifier: result.language) ?? result.language
                metaRow("Language", value: display)
            }
            if let bytes = result.sizeBytes {
                metaRow("Size", value: ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
            }
            metaRow("Source", value: sourcePluginName ?? "Plugin")
            // Plugin-supplied extras (publisher, ISBN, subjects, etc.).
            // Rendered in the order the plugin returned them — same row
            // styling so the inspector reads as one continuous table.
            ForEach(Array(result.metadata.enumerated()), id: \.offset) { _, field in
                metaRow(field.key, value: field.value)
            }
        }
    }

    @ViewBuilder
    private func sourceActions(for result: PluginResult) -> some View {
        VStack(spacing: 0) {
            if case .downloading = sourceDownloadState {
                // Same row, different action: while downloading the row
                // becomes a cancel target. Title still shows progress so the
                // primary feedback is preserved; hovering swaps icon+title to
                // make cancel obvious.
                SourceCancelRow(
                    progressTitle: sourceActionTitle,
                    onCancel: onSourceCancel
                )
            } else {
                Button(action: onSourceDownload) {
                    actionLabel(icon: sourceActionIcon, title: sourceActionTitle)
                }
                .disabled(sourceDownloadState == .importing || sourceDownloadState == .added)
            }

            if let url = result.detailURL {
                Link(destination: url) {
                    actionLabel(icon: "safari", title: "Open in browser")
                }
            }
        }
        .buttonStyle(MenuRowStyle())
    }

    private var sourceActionIcon: String {
        switch sourceDownloadState {
        case .idle: return "icloud.and.arrow.down"
        case .downloading: return "arrow.down"
        case .importing: return "checkmark"
        case .added: return "checkmark"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var sourceActionTitle: String {
        switch sourceDownloadState {
        case .idle: return sourceDownloadIdleTitle
        case .downloading(let progress):
            if let progress { return "Downloading \(Int(progress * 100))%" }
            return "Downloading…"
        case .importing: return "Adding to library…"
        case .added: return "Added to library"
        case .error: return "Try again"
        }
    }
}

/// Inspector action row for the in-flight download state. Resting label
/// shows "Downloading 42%" so progress stays the primary signal; on hover,
/// icon and title swap to "Cancel download" so the cancel affordance only
/// reveals when the user is reaching for it.
private struct SourceCancelRow: View {
    let progressTitle: String
    let onCancel: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onCancel) {
            HStack(spacing: 9) {
                Icon(symbol: isHovering ? "xmark" : "arrow.down", weight: .regular, size: 13)
                    .frame(width: 14)
                Text(isHovering ? "Cancel download" : progressTitle)
            }
        }
        .onHover { isHovering = $0 }
        .help("Cancel download")
    }
}

/// A removable pill showing the book's membership in one collection.
/// X is hover-revealed on mouse-over so an idle inspector reads cleanly;
/// tapping it removes the book from the collection without confirmation
/// (it's reversible from the same chip's "+" picker).
private struct CollectionChip: View {
    let name: String
    let onRemove: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)

            Button(action: onRemove) {
                Icon(symbol: "xmark", weight: .bold, size: 9)
                    .foregroundStyle(.primary.opacity(hovered ? 0.85 : 0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.08)))
        .overlay(Capsule(style: .continuous).stroke(Theme.hairline, lineWidth: 0.5))
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

/// "+" pill that opens a popover listing the collections this book *isn't*
/// in yet, plus a "New Collection…" inline-create option. Selecting an
/// existing collection adds the book to it; submitting a new name creates
/// the collection and adds the book in one step.
private struct AddCollectionChip: View {
    let available: [Collection]
    let onAdd: (UUID) -> Void
    let onCreateAndAdd: (String) -> Void

    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover = true
        } label: {
            HStack(spacing: 4) {
                Icon(symbol: "plus", weight: .bold, size: 9)
                    .foregroundStyle(.primary.opacity(Theme.Text.secondary))
                Text("Add")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.primary.opacity(Theme.Text.secondary))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(Color.clear))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(.primary.opacity(Theme.Surface.dropTarget), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            AddCollectionPopover(
                available: available,
                onAdd: { id in
                    onAdd(id)
                    showPopover = false
                },
                onCreateAndAdd: { name in
                    onCreateAndAdd(name)
                    showPopover = false
                }
            )
        }
    }
}

/// Popover content for the "+" chip: a flat list of collections the book
/// isn't in, plus an inline-create entry that turns into a TextField on tap.
private struct AddCollectionPopover: View {
    let available: [Collection]
    let onAdd: (UUID) -> Void
    let onCreateAndAdd: (String) -> Void

    @State private var creating = false
    @State private var newName = ""
    @FocusState private var newFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(available) { collection in
                Button {
                    onAdd(collection.id)
                } label: {
                    // Existing collections render as plain rows — no icon —
                    // so the "New Collection…" entry's "+" reads as the
                    // distinct *create* action, not a generic bullet.
                    Text(collection.name)
                }
            }

            if !available.isEmpty {
                MenuDivider()
            }

            if creating {
                TextField("Collection name", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($newFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.menuItem, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .padding(.horizontal, Theme.Spacing.menuInset)
                    .onSubmit { commitCreate() }
                    .onAppear { newFocused = true }
                // No commit-on-blur: when the popover dismisses by
                // outside-click, the popover removal and focus-loss
                // notification race; the typed name can be lost. Enter
                // commits, click-away cancels.
            } else {
                Button {
                    creating = true
                } label: {
                    HStack(spacing: 9) {
                        Icon(symbol: "plus", weight: .regular, size: 11)
                            .frame(width: 14)
                        Text("New Collection…")
                    }
                }
            }
        }
        .menuPopoverContainer(minWidth: 220)
    }

    private func commitCreate() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCreateAndAdd(trimmed)
        newName = ""
        creating = false
    }
}
