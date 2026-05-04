import SwiftUI
import AppKit
import PhosphorSwift

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

    /// Profiles available to the locale Picker. Plain data, OK to pass in.
    let profiles: [LanguageProfile]

    let onUpdate: (Book) -> Void
    /// Runs the classifier on the inspector's book. Returns the classifier
    /// result (or nil if classification fails). The inspector applies the
    /// result via `onUpdate`.
    let onClassify: () async -> Classification?
    let onSetCoverFromFile: (URL) -> Void
    let onSetCoverFromImage: (NSImage) -> Void
    let onRemoveCover: () -> Void
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

    /// Sentinel tag for the "Auto-detect from text" Picker entry.
    private static let autoDetectTag = "__autodetect__"

    /// Transient confidence read-out shown beneath the locale picker after
    /// auto-detect. Cleared after a few seconds — confidence isn't persisted.
    @State private var transientClassification: Classification?
    @State private var classifyingTask: Task<Void, Never>?
    @State private var clearConfidenceTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Theme.panel

            if let book {
                content(for: book)
            } else if let multiBooks, !multiBooks.isEmpty {
                multiContent(books: multiBooks)
            } else {
                emptyState
            }
        }
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
                .foregroundStyle(.primary.opacity(0.42))
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
                    .padding(.bottom, 64) // clear bottom-chrome toggle
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
                        icon: .deviceTablet,
                        title: "Send \(info.sendableCount) to \(info.displayName)"
                    )
                }
            }
            ShareLink(items: books.map(\.fileURL)) {
                actionLabel(icon: .share, title: "Share \(books.count)…")
            }
            Button(role: .destructive, action: onRequestDeleteMulti) {
                actionLabel(icon: .trash, title: "Move \(books.count) to Trash…")
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

                actions(for: book)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.bottom, 64) // clear bottom-chrome toggle
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
                onRemoveCover: onRemoveCover
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
                        let parsed = newValue
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
            metaRow("File", value: book.fileURL.lastPathComponent, monospaced: true)
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
                Text("Detected: \(display) · \(pct)% confidence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 76)
                    .padding(.vertical, 4)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: transientClassification)
    }

    private func localePicker(for book: Book) -> some View {
        Picker(selection: pickerSelection(for: book)) {
            Text("Auto-detect from text").tag(Self.autoDetectTag)
            Divider()
            Text(Locale.current.localizedString(forIdentifier: "und") ?? "Unknown").tag("und")
            ForEach(profiles) { profile in
                Text(profile.displayName).tag(profile.id)
            }
            // Keep the current value selectable when it isn't a known
            // profile (e.g. "pt" without variant) so it isn't silently lost.
            if shouldShowDeclaredOption(for: book) {
                let baseName = Locale.current.localizedString(forIdentifier: book.locale) ?? book.locale
                Text("\(baseName) (declared)").tag(book.locale)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
    }

    private func pickerSelection(for book: Book) -> Binding<String> {
        Binding(
            get: { book.locale },
            set: { newValue in
                if newValue == Self.autoDetectTag {
                    runAutoDetect(for: book)
                } else if newValue != book.locale {
                    var updated = book
                    updated.locale = newValue
                    onUpdate(updated)
                }
            }
        )
    }

    private func shouldShowDeclaredOption(for book: Book) -> Bool {
        book.locale != "und" &&
        !profiles.contains(where: { $0.id == book.locale })
    }

    private func runAutoDetect(for book: Book) {
        classifyingTask?.cancel()
        clearConfidenceTask?.cancel()
        let bookID = book.id
        classifyingTask = Task { @MainActor in
            let result = await onClassify()
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
            .foregroundStyle(.primary.opacity(0.42))
            .frame(width: 76, alignment: .leading)
    }

    @ViewBuilder
    private func actions(for book: Book) -> some View {
        VStack(spacing: 0) {
            if let device, device.canSend {
                Button(action: onSendToDevice) {
                    actionLabel(
                        icon: device.isOnDevice ? .check : .deviceTablet,
                        title: device.isOnDevice ? "On \(device.displayName)" : "Send to \(device.displayName)"
                    )
                }
                .disabled(device.isOnDevice)
                .opacity(device.isOnDevice ? 0.5 : 1.0)
            }
            Button(action: onShowInFinder) {
                actionLabel(icon: .folderOpen, title: "Show in Finder")
            }
            ShareLink(item: book.fileURL) {
                actionLabel(icon: .share, title: "Share…")
            }
            Button(role: .destructive, action: onRequestDelete) {
                actionLabel(icon: .trash, title: "Move to Trash…")
            }
        }
        .buttonStyle(MenuRowStyle())
    }

    private func actionLabel(icon: Ph, title: String) -> some View {
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
}
