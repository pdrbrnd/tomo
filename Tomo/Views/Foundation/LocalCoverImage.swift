import AppKit
import SwiftUI

/// Renders a cover image from disk, with a typography placeholder when no
/// cover URL is provided. Single owner for the missing-cover treatment.
struct LocalCoverImage: View {
    let url: URL?
    var fallbackTitle: String? = nil
    var fallbackAuthor: String? = nil

    @State private var image: NSImage?

    var body: some View {
        // `Color.clear` is the load-bearing primitive: flexible, always
        // reports the proposed size to its parent, never propagates inner
        // content size up. Putting the image inside `.overlay` means its
        // `.aspectRatio(.fill)` overflow is visual-only — it does NOT
        // propagate as an intrinsic frame back to the parent. `.frame`
        // alone wouldn't be enough; that modifier caps but doesn't force,
        // so an oversized child still bubbles up. Without this, non-2:3
        // covers (common from Google Books) push `BookCard`'s
        // selected-state overlay against the overflow's bounds and the
        // bottom-aligned title/author drops below the visible card.
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    placeholder
                }
            }
            .clipped()
            .task(id: url) { await load() }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let title = fallbackTitle, !title.isEmpty {
            typographyPlaceholder(title: title, author: fallbackAuthor)
        } else {
            iconPlaceholder
        }
    }

    private var iconPlaceholder: some View {
        ZStack {
            Theme.surface
            LinearGradient(
                colors: [.primary.opacity(0.05), .primary.opacity(0.12)],
                startPoint: .top,
                endPoint: .bottom
            )
            Image(systemName: "book.closed")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.primary.opacity(0.35))
        }
    }

    private func typographyPlaceholder(title: String, author: String?) -> some View {
        ZStack {
            Theme.surface
            LinearGradient(
                colors: [.primary.opacity(0.04), .primary.opacity(0.10)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary.opacity(Theme.Text.primary))
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                if let author, !author.isEmpty {
                    Text(author)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.primary.opacity(Theme.Text.secondary))
                        .lineLimit(2)
                        .tracking(0.1)
                        .textCase(.uppercase)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
        }
    }

    private func load() async {
        guard let url else {
            image = nil
            return
        }
        image = await Task.detached { NSImage(contentsOf: url) }.value
    }
}
