import AppKit
import SwiftUI

/// Renders a cover image from disk, with a typography placeholder when no
/// cover URL is provided. Single owner for the missing-cover treatment.
struct LocalCoverImage: View {
    let url: URL?
    var fallbackTitle: String? = nil
    var fallbackAuthor: String? = nil
    /// External hint that a cover *will* arrive even though `url` is nil
    /// right now (e.g. plugin search still running, post-search enricher
    /// not done). Drives the skeleton when the URL itself isn't set yet.
    /// Once `url` is non-nil, the internal fetch state takes over —
    /// skeleton stays up until the image actually loads.
    var isLoading: Bool = false

    @State private var image: NSImage?
    @State private var isFetching = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var skeletonPulse = false

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
                        .transition(.opacity)
                } else if showsSkeleton {
                    skeleton
                        .transition(.opacity)
                } else {
                    placeholder
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: image == nil)
            .clipped()
            .task(id: url) { await load() }
    }

    /// True while we're either actively fetching the image, or the parent
    /// has flagged a pending cover that hasn't even produced a URL yet.
    private var showsSkeleton: Bool {
        isFetching || (url == nil && isLoading)
    }

    /// Soft surface pulse — same gradient stack as the typography
    /// placeholder so the eventual cover crossfades in cleanly rather
    /// than swapping a solid skeleton for a textured fallback.
    private var skeleton: some View {
        ZStack {
            Theme.surface
            LinearGradient(
                colors: [.primary.opacity(0.04), .primary.opacity(0.10)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .opacity(skeletonPulse ? 1.0 : 0.55)
        .animation(
            reduceMotion
                ? .easeInOut(duration: 0.4)
                : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
            value: skeletonPulse
        )
        .onAppear { skeletonPulse = true }
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
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary.opacity(Theme.Text.primary))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if let author, !author.isEmpty {
                    Text(author)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.primary.opacity(Theme.Text.secondary))
                        .lineLimit(2)
                        .tracking(0.1)
                        .textCase(.uppercase)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(14)
        }
    }

    private func load() async {
        guard let url else {
            image = nil
            isFetching = false
            return
        }
        // Reset image so a URL change re-triggers the skeleton instead of
        // showing the previous cover during the new fetch.
        image = nil
        isFetching = true
        defer { isFetching = false }
        image = await Task.detached { NSImage(contentsOf: url) }.value
    }
}
