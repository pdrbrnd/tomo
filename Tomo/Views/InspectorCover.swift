import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreTransferable
import os

/// Cover image inside the inspector with editing affordances:
///
/// - Drop an image (Finder file, web image, app drag, Photos) → replace cover.
/// - Click the cover to focus, cmd+V (or Edit > Paste) → paste from clipboard.
/// - Hover → corner pills appear: Choose File, Search Online.
/// - Right-click → menu with Replace…, Search Online…, Remove.
struct InspectorCover: View {
    let book: Book
    let onSetCoverFromFile: (URL) -> Void
    let onSetCoverFromImage: (NSImage) -> Void
    let onRemoveCover: () -> Void
    let onChooseFromOpenLibrary: () -> Void

    @State private var dropTargeted = false
    @State private var hovered = false
    @FocusState private var coverFocused: Bool

    private static let coverWidth: CGFloat = 132
    private static let coverHeight: CGFloat = 198

    var body: some View {
        LocalCoverImage(url: book.coverURL, fallbackTitle: book.title)
            .frame(width: Self.coverWidth, height: Self.coverHeight)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover + 2, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.cover + 2, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 0.5)
            )
            .overlay(focusHighlight)
            .overlay(dropHighlight)
            .overlay(alignment: .topTrailing) { cornerButtons }
            .softShadow(elevated: false)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.cover + 2, style: .continuous))
            .focusable()
            .focused($coverFocused)
            .focusEffectDisabled()
            .onTapGesture { coverFocused = true }
            .contextMenu {
                Button("Replace…") { presentReplaceDialog() }
                Button("Search Online…") { onChooseFromOpenLibrary() }
                if book.coverPath != nil {
                    Divider()
                    Button("Remove Cover", role: .destructive) { onRemoveCover() }
                }
            }
            .dropDestination(for: DroppedCover.self) { items, _ in
                guard let img = items.first.flatMap({ NSImage(data: $0.data) }) else { return false }
                onSetCoverFromImage(img)
                return true
            } isTargeted: { dropTargeted = $0 }
            .onPasteCommand(of: [UTType.image]) { providers in
                Task { await handlePaste(from: providers) }
            }
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.15), value: hovered)
            .animation(.easeOut(duration: 0.15), value: coverFocused)
            .animation(.easeOut(duration: 0.15), value: dropTargeted)
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: Theme.Radius.cover + 2, style: .continuous)
                .stroke(Color.accentColor, lineWidth: 2)
                .padding(-1)
        }
    }

    @ViewBuilder
    private var focusHighlight: some View {
        if coverFocused && !dropTargeted {
            RoundedRectangle(cornerRadius: Theme.Radius.cover + 2, style: .continuous)
                .stroke(Color.accentColor, lineWidth: 2)
                .padding(-1)
        }
    }

    private var showCornerButtons: Bool {
        hovered || coverFocused || dropTargeted
    }

    @ViewBuilder
    private var cornerButtons: some View {
        if showCornerButtons {
            HStack(spacing: Theme.Spacing.xs) {
                cornerButton(symbol: "folder", help: "Choose File…", action: presentReplaceDialog)
                cornerButton(symbol: "globe", help: "Search Online…", action: onChooseFromOpenLibrary)
            }
            .padding(Theme.Spacing.sm)
            .transition(.opacity)
        }
    }

    private func cornerButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Circle().fill(Color.black.opacity(0.62))
                Icon(symbol: symbol, weight: .bold, size: 9)
                    .foregroundStyle(Color.white)
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @MainActor
    private func handlePaste(from providers: [NSItemProvider]) async {
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { continue }
            do {
                let data = try await loadImageData(from: provider)
                if let image = NSImage(data: data) {
                    onSetCoverFromImage(image)
                    return
                }
            } catch {
                metadataLogger.error("paste cover failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private nonisolated func loadImageData(from provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    private func presentReplaceDialog() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                onSetCoverFromFile(url)
            }
        }
    }
}

/// Transferable wrapper that imports raw image bytes from any registered
/// image content type — covers Finder file drags (system reads the file's
/// bytes), web/app/Photos drags, all through one drop path.
private nonisolated struct DroppedCover: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            DroppedCover(data: data)
        }
    }
}
