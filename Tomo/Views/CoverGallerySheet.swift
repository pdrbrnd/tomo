import SwiftUI
import AppKit

/// Sheet that surfaces Open Library cover candidates for a book and lets
/// the user pick one. Search is seeded from the book's title + first author;
/// both are editable. Network fetches happen only here — opening the sheet
/// is the user's explicit action.
struct CoverGallerySheet: View {
    let book: Book
    let onPick: (NSImage) -> Void
    let onCancel: () -> Void

    @State private var titleQuery: String
    @State private var authorQuery: String
    @State private var loadState: LoadState = .idle
    @State private var selectedCoverID: Int?
    @State private var fetching = false

    init(book: Book, onPick: @escaping (NSImage) -> Void, onCancel: @escaping () -> Void) {
        self.book = book
        self.onPick = onPick
        self.onCancel = onCancel
        _titleQuery = State(initialValue: book.title)
        _authorQuery = State(initialValue: book.authors.first ?? "")
    }

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded([CoverCandidate])
        case error(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            insetRule
            content
            insetRule
            footer
        }
        .frame(width: 720, height: 560)
        .task { await runSearch() }
    }

    /// Edge-to-edge hairline, mirroring the `metaRow` rules in `BookInspector`.
    /// Each section owns its own horizontal padding so this rule spans the
    /// full sheet width — the system's rounded-corner clip trims its ends.
    private var insetRule: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 0.5)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            queryField(text: $titleQuery, placeholder: "Title")
            queryField(text: $authorQuery, placeholder: "Author")
            Button("Search") { Task { await runSearch() } }
                .buttonStyle(PillButtonStyle(prominent: true))
                .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.lg)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .idle, .loading:
            centered { ProgressView() }
        case .loaded(let candidates) where candidates.isEmpty:
            centered {
                Text("No covers found.")
                    .foregroundStyle(.secondary)
                Text("Try editing the title or author.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case .loaded(let candidates):
            grid(candidates)
        case .error(let message):
            centered {
                Text(message).foregroundStyle(.secondary)
                Button("Retry") { Task { await runSearch() } }
            }
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

    private func grid(_ candidates: [CoverCandidate]) -> some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.md), count: 4),
                spacing: Theme.Spacing.md
            ) {
                ForEach(candidates) { candidate in
                    coverCell(candidate)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.sm)
        }
    }

    private func coverCell(_ candidate: CoverCandidate) -> some View {
        let selected = selectedCoverID == candidate.coverID
        return Button {
            selectedCoverID = candidate.coverID
        } label: {
            AsyncImage(url: OpenLibraryService.coverURL(candidate.coverID, size: .medium)) { phase in
                switch phase {
                case .empty:
                    ZStack {
                        Theme.surface
                        ProgressView().controlSize(.small)
                    }
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    ZStack {
                        Theme.surface
                        Icon(symbol: "exclamationmark.triangle", weight: .regular, size: 18)
                            .foregroundStyle(.secondary)
                    }
                @unknown default:
                    Theme.surface
                }
            }
            .frame(height: 220)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 0.5)
            )
            .softShadow(elevated: selected)
            .overlay(selectionRing(visible: selected))
            .animation(.easeOut(duration: 0.15), value: selected)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func selectionRing(visible: Bool) -> some View {
        if visible {
            RoundedRectangle(cornerRadius: Theme.Radius.cover + 2, style: .continuous)
                .stroke(Color.accentColor, lineWidth: 2)
                .padding(-3)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel") { onCancel() }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.cancelAction)
            Spacer()
            if fetching {
                ProgressView().controlSize(.small).padding(.trailing, Theme.Spacing.sm)
            }
            Button("Use This Cover") { Task { await commit() } }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(selectedCoverID == nil || fetching)
                .keyboardShortcut(.return)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.xl)
    }

    // MARK: - Field

    private func queryField(text: Binding<String>, placeholder: String) -> some View {
        GalleryQueryField(text: text, placeholder: placeholder) {
            Task { await runSearch() }
        }
    }

    // MARK: - Actions

    private func runSearch() async {
        let title = titleQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            loadState = .loaded([])
            return
        }
        loadState = .loading
        selectedCoverID = nil
        let author = authorQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let candidates = try await OpenLibraryService.searchCovers(
                title: title,
                author: author.isEmpty ? nil : author
            )
            loadState = .loaded(candidates)
        } catch let error as OpenLibraryError {
            loadState = .error(error.errorDescription ?? "Couldn't reach Open Library.")
        } catch {
            loadState = .error("Couldn't reach Open Library.")
        }
    }

    private func commit() async {
        guard let coverID = selectedCoverID else { return }
        fetching = true
        defer { fetching = false }
        do {
            let data = try await OpenLibraryService.fetchCoverData(coverID: coverID, size: .large)
            guard let image = NSImage(data: data) else {
                loadState = .error("Couldn't decode the selected cover.")
                return
            }
            onPick(image)
        } catch let error as OpenLibraryError {
            loadState = .error(error.errorDescription ?? "Couldn't download the cover.")
        } catch {
            loadState = .error("Couldn't download the cover.")
        }
    }
}

/// Capsule text field matching `SearchPill`'s aesthetic, parameterised so
/// the gallery sheet's two side-by-side fields read as one cohesive search
/// row instead of system-default rounded borders.
private struct GalleryQueryField: View {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(.primary.opacity(0.42)))
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.primary.opacity(0.92))
            .focused($focused)
            .onSubmit(onSubmit)
            .padding(.horizontal, 13)
            .frame(height: 32)
            .frame(maxWidth: .infinity)
            .background(
                ZStack {
                    Capsule(style: .continuous).fill(Theme.surface)
                    Capsule(style: .continuous).stroke(Theme.hairline, lineWidth: 0.5)
                }
            )
            .contentShape(Capsule(style: .continuous))
            .onTapGesture { focused = true }
    }
}
