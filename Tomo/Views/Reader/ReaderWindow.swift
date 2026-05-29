import AppKit
import SwiftUI

/// A transparent overlay that makes a chromeless window draggable by its
/// edges. It hit-tests as itself only within `edgeWidth` of the bounds and
/// returns nil elsewhere, so edge clicks move the window (via
/// `mouseDownCanMoveWindow`) while clicks in the centre fall through to the
/// content below for scrolling and text selection.
struct WindowEdgeDragRegion: NSViewRepresentable {
    var edgeWidth: CGFloat = 24

    func makeNSView(context: Context) -> NSView {
        let view = EdgeDragView()
        view.edgeWidth = edgeWidth
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? EdgeDragView)?.edgeWidth = edgeWidth
    }
}

private final class EdgeDragView: NSView {
    var edgeWidth: CGFloat = 24

    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let nearEdge =
            local.x < edgeWidth || local.x > bounds.width - edgeWidth
            || local.y < edgeWidth || local.y > bounds.height - edgeWidth
        return nearEdge ? self : nil
    }
}

/// What the reader window is showing. A `.book` is a library book (carries a
/// stable id, so its reading position persists); a `.looseFile` is a file
/// opened from Finder without importing (no id, no remembered position).
enum ReaderTarget: Equatable {
    case book(Book)
    case looseFile(URL)

    var fileURL: URL {
        switch self {
        case .book(let book): book.fileURL
        case .looseFile(let url): url
        }
    }

    var title: String {
        switch self {
        case .book(let book): book.title
        case .looseFile(let url): url.deletingPathExtension().lastPathComponent
        }
    }

    var bookID: UUID? {
        switch self {
        case .book(let book): book.id
        case .looseFile: nil
        }
    }
}

/// Root of the standalone reader window. Reads the current target from
/// `AppState` and routes to the format-specific reader. Re-keyed on the file
/// URL so switching books rebuilds the reader cleanly.
struct ReaderWindowRoot: View {
    let state: AppState

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()

            if let target = state.readerTarget {
                content(for: target)
                    .id(target.fileURL)
            } else {
                Text("No book open.")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(Theme.Text.secondary))
            }
        }
        .background(WindowCustomizer())
        // Min width keeps side margins around the ~62ch column even when the
        // user shrinks the window, so text never tucks under the chrome.
        .frame(minWidth: 720, minHeight: 560)
        .ignoresSafeArea(.all)
    }

    @ViewBuilder
    private func content(for target: ReaderTarget) -> some View {
        switch target.fileURL.pathExtension.lowercased() {
        case "pdf":
            PDFReaderScreen(fileURL: target.fileURL, bookID: target.bookID, title: target.title)
        default:
            EPUBReaderView(fileURL: target.fileURL, bookID: target.bookID, title: target.title)
        }
    }
}
