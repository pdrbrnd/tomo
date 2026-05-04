import SwiftUI
import AppKit
import os

/// Sheet that surfaces cover candidates from Open Library + Google Books for
/// a book and lets the user pick one. Search is seeded from the book's title
/// + first author; both are editable. Network fetches happen only here —
/// opening the sheet is the user's explicit action.
struct CoverGallerySheet: View {
    let book: Book
    let onPick: (Data) -> Void
    let onCancel: () -> Void

    @State private var titleQuery: String
    @State private var authorQuery: String
    @State private var loadState: LoadState = .idle
    @State private var selectedCandidateID: String?
    @State private var fetching = false
    @State private var searchTask: Task<Void, Never>?

    init(book: Book, onPick: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
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
        .frame(width: 720, height: 640)
        .onAppear { startSearch() }
        .onDisappear { searchTask?.cancel() }
    }

    /// Cancel any in-flight search and start a new one. Without this, rapid
    /// Cmd+Return / Search clicks race two parallel-source searches against
    /// each other and the *last to resolve* wins — not the most recent one
    /// the user kicked off.
    private func startSearch() {
        searchTask?.cancel()
        searchTask = Task { await runSearch() }
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
            Button("Search") { startSearch() }
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
                Button("Retry") { startSearch() }
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
        let selected = selectedCandidateID == candidate.id
        return Button {
            selectedCandidateID = candidate.id
        } label: {
            // Color.clear is the load-bearing layout primitive: it accepts
            // any size in any direction, so .aspectRatio(2/3, .fit) gives
            // a determined-size frame, and the AsyncImage inside the overlay
            // is hard-constrained to that frame. Putting aspectRatio directly
            // on AsyncImage doesn't constrain it reliably when the loaded
            // image is much larger than the cell — it can overflow into
            // neighbouring cells. (See: the "TH" giant-letters bug.)
            //
            // Books are ~95% within 1:1.4 → 1:1.6 so .fill crops invisibly
            // for the common case; the rare square/wide cover loses a sliver
            // — acceptable trade in a chooser.
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    AsyncImage(url: candidate.thumbnailURL) { phase in
                        switch phase {
                        case .empty:
                            ZStack {
                                Theme.surface
                                ProgressView().controlSize(.small)
                            }
                        case .success(let image):
                            image.resizable().scaledToFill()
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
                }
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
                .disabled(selectedCandidateID == nil || fetching)
                .keyboardShortcut(.return)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.xl)
    }

    // MARK: - Field

    private func queryField(text: Binding<String>, placeholder: String) -> some View {
        GalleryQueryField(text: text, placeholder: placeholder) {
            startSearch()
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
        selectedCandidateID = nil
        let author = authorQuery.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        // Hit all three sources in parallel and concat in *quality order*:
        // iTunes (publisher artwork, no placeholder problem) → Open Library
        // (broad indie/older catalogue) → Google Books (last-resort, already
        // dimension-filtered in the service to drop "image not available"
        // placeholders). Per-source failures don't poison the others — only
        // fail loud if all three error out.
        async let iTunes = trySearch { try await iTunesSearchService.searchCovers(title: title, author: author) }
        async let openLibrary = trySearch { try await OpenLibraryService.searchCovers(title: title, author: author) }
        async let googleBooks = trySearch { try await GoogleBooksService.searchCovers(title: title, author: author) }

        let (it, ol, gb) = await (iTunes, openLibrary, googleBooks)
        if Task.isCancelled { return }
        if it == nil && ol == nil && gb == nil {
            loadState = .error("Couldn't reach the cover sources.")
        } else {
            loadState = .loaded((it ?? []) + (ol ?? []) + (gb ?? []))
        }
    }

    private func trySearch(_ work: () async throws -> [CoverCandidate]) async -> [CoverCandidate]? {
        do {
            return try await work()
        } catch {
            metadataLogger.error("cover search failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func commit() async {
        guard let id = selectedCandidateID,
              case .loaded(let candidates) = loadState,
              let candidate = candidates.first(where: { $0.id == id }) else { return }
        fetching = true
        defer { fetching = false }
        do {
            let data = try await fetchCoverBytes(from: candidate.fullURL)
            onPick(data)
        } catch let error as CoverFetchError {
            loadState = .error(error.errorDescription ?? "Couldn't download the cover.")
        } catch {
            loadState = .error("Couldn't download the cover.")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
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
