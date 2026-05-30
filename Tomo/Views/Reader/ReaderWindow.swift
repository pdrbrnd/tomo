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

/// What a reader window is showing — the value a reader `WindowGroup` window
/// is bound to. `Codable`/`Hashable` so each route gets its own independent
/// window (like Books' reading windows) and windows restore across launches.
/// A `bookID` means a library book (reading position persists); nil means a
/// file opened loose from Finder.
struct ReaderRoute: Codable, Hashable {
    let fileURL: URL
    let bookID: UUID?
}

/// Root of a standalone reader window. One window per `ReaderRoute`; the
/// library is never involved. Re-keyed on the file URL so switching the
/// displayed file rebuilds the reader cleanly.
struct ReaderWindowRoot: View {
    let route: ReaderRoute?
    let state: AppState
    /// Set after "Add to Library" so the window keeps reading in place but now
    /// against the imported book's id (position persists, the bar disappears).
    @State private var override: ReaderRoute?
    @State private var importing = false

    private var active: ReaderRoute? { override ?? route }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()

            if let active {
                content(for: active)
                    .id(active.fileURL)
            } else {
                Text("No book open.")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(Theme.Text.secondary))
            }

            // A file opened from Finder isn't in the library until the user
            // says so — nothing happens to it without this explicit tap.
            if let active, active.bookID == nil {
                addToLibraryBar(url: active.fileURL)
            }
        }
        .background(WindowCustomizer())
        .background(
            WindowAccessor { window in
                // Front + activate on open so a reader opened from Finder lands
                // on top even when the library window also exists.
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
        )
        // Min width keeps side margins around the ~62ch column even when the
        // user shrinks the window, so text never tucks under the chrome.
        .frame(minWidth: 720, minHeight: 560)
        .ignoresSafeArea(.all)
        // Window title — invisible in the chromeless window, but labels each
        // reader window in the Window menu and Mission Control.
        .navigationTitle(active.map(resolvedTitle) ?? "Reader")
    }

    private func addToLibraryBar(url: URL) -> some View {
        Button {
            addToLibrary(url)
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                if importing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus.circle")
                }
                Text(importing ? "Adding…" : "Add to Library")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(Theme.overlaySurface, in: Capsule())
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 0.5))
            .softShadow(elevated: false)
        }
        .buttonStyle(.plain)
        .disabled(importing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, Theme.Spacing.xxl)
    }

    private func addToLibrary(_ url: URL) {
        guard !importing else { return }
        importing = true
        Task {
            let book = await state.importBook(from: url)
            importing = false
            // On success, switch to the imported book so the bar disappears
            // and reading position now persists against a stable id — and
            // reveal the library window (it may have been suppressed at
            // launch). This is the one moment the main view should appear.
            if let book {
                override = ReaderRoute(fileURL: book.fileURL, bookID: book.id)
                state.showLibraryWindow()
            }
        }
    }

    @ViewBuilder
    private func content(for route: ReaderRoute) -> some View {
        switch route.fileURL.pathExtension.lowercased() {
        case "pdf":
            PDFReaderScreen(fileURL: route.fileURL, bookID: route.bookID)
        default:
            EPUBReaderView(fileURL: route.fileURL, bookID: route.bookID)
        }
    }

    /// Library books get their stored title; loose files fall back to the
    /// filename.
    private func resolvedTitle(for route: ReaderRoute) -> String {
        if let id = route.bookID, let book = state.books.first(where: { $0.id == id }) {
            return book.title
        }
        return route.fileURL.deletingPathExtension().lastPathComponent
    }
}
