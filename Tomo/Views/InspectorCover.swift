import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Cover image inside the inspector with editing affordances.
///
/// - Drop an image file → replace cover.
/// - Right-click → menu: Replace… (file picker), Paste, Remove.
struct InspectorCover: View {
    let book: Book
    let onSetCoverFromFile: (URL) -> Void
    let onSetCoverFromImage: (NSImage) -> Void
    let onRemoveCover: () -> Void

    @State private var dropTargeted = false

    var body: some View {
        LocalCoverImage(url: book.coverURL, fallbackTitle: book.title)
            .frame(width: 132, height: 198)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover + 2, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.cover + 2, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 0.5)
            )
            .overlay(dropHighlight)
            .softShadow(elevated: false)
            .contextMenu {
                Button("Replace…") { presentReplaceDialog() }
                Button("Paste from Clipboard") { pasteFromClipboard() }
                    .disabled(!clipboardHasImage)
                if book.coverPath != nil {
                    Divider()
                    Button("Remove Cover", role: .destructive) { onRemoveCover() }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let first = urls.first(where: { Self.isImageURL($0) }) else { return false }
                onSetCoverFromFile(first)
                return true
            } isTargeted: { dropTargeted = $0 }
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: Theme.Radius.cover + 2, style: .continuous)
                .stroke(Color.accentColor, lineWidth: 2)
                .padding(-1)
        }
    }

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "tiff", "webp", "heic", "bmp"]

    private static func isImageURL(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    private var clipboardHasImage: Bool {
        let pb = NSPasteboard.general
        return pb.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    private func pasteFromClipboard() {
        let pb = NSPasteboard.general
        guard let image = pb.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage else {
            return
        }
        onSetCoverFromImage(image)
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
