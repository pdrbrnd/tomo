import AppKit
import SwiftUI

/// Drag preview rendered during in-app book drags.
///
/// Two important quirks shaped this view:
///  1. The preview is rendered to a static bitmap by macOS at drag start —
///     so async cover loading (`LocalCoverImage` via `.task`) doesn't finish
///     in time. We load `NSImage(contentsOf:)` synchronously here. For the
///     small cover files in a personal library this takes ~ms.
///  2. The fallback for missing covers is a centered book icon — never the
///     typography placeholder, because long titles wrap into ugly shapes at
///     the small preview size.
struct BookDragPreview: View {
    let books: [Book]

    private static let cardWidth: CGFloat = Theme.Library.dragPreviewWidth
    private static let cardHeight: CGFloat =
        Theme.Library.dragPreviewWidth
        * Theme.Library.bookHeightMultiplier

    var body: some View {
        let w = Self.cardWidth
        let h = Self.cardHeight
        return ZStack {
            ForEach(Array(stack.enumerated()), id: \.offset) { index, book in
                cover(for: book)
                    .rotationEffect(.degrees(rotation(for: index)), anchor: .center)
                    .offset(offset(for: index))
                    .zIndex(Double(index))
            }

            if books.count > 1 {
                countBadge
                    .offset(x: w * 0.42, y: -h * 0.46)
                    .zIndex(99)
            }
        }
        .frame(width: w + 24, height: h + 24)
    }

    private var stack: [Book] {
        Array(books.prefix(3)).reversed()
    }

    private func cover(for book: Book) -> some View {
        DragCover(book: book)
            .frame(width: Self.cardWidth, height: Self.cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 3)
    }

    private func rotation(for indexInStack: Int) -> Double {
        let topIndex = stack.count - 1
        let depth = topIndex - indexInStack
        switch depth {
        case 0: return 0
        case 1: return -3
        case 2: return 3
        default: return 0
        }
    }

    private func offset(for indexInStack: Int) -> CGSize {
        let topIndex = stack.count - 1
        let depth = topIndex - indexInStack
        switch depth {
        case 0: return .zero
        case 1: return CGSize(width: -4, height: -2)
        case 2: return CGSize(width: 4, height: 2)
        default: return .zero
        }
    }

    private var countBadge: some View {
        Text("\(books.count)")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white)
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.95), lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1.5)
    }
}

/// One card in the drag preview. Loads the cover synchronously off-disk so
/// the bitmap captured at drag start contains the actual artwork — not the
/// typography placeholder used elsewhere.
private struct DragCover: View {
    let book: Book

    var body: some View {
        if let image = loadCover() {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            iconFallback
        }
    }

    private func loadCover() -> NSImage? {
        guard let url = book.coverURL else { return nil }
        return NSImage(contentsOf: url)
    }

    private var iconFallback: some View {
        ZStack {
            Theme.surface
            LinearGradient(
                colors: [.primary.opacity(0.05), .primary.opacity(0.12)],
                startPoint: .top,
                endPoint: .bottom
            )
            Icon(symbol: "book.closed", weight: .light, size: 22)
                .foregroundStyle(.primary.opacity(0.4))
        }
    }
}
