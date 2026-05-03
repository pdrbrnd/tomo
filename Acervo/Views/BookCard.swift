import SwiftUI
import PhosphorSwift

/// Book card: cover at rest, backdrop-blurred dark overlay with title + author
/// + 3-dot menu when selected. The card is gesture-agnostic — the parent
/// wires single/double tap and the menu items.
///
/// `MenuContent` is a `@ViewBuilder` so the parent passes Buttons directly,
/// the same pattern as React's `children`. The card just decides where the
/// menu lives (the 3-dot popover and the right-click contextMenu).
struct BookCard<MenuContent: View>: View {
    let book: Book
    let isSelected: Bool
    let cardWidth: CGFloat
    @ViewBuilder var menu: () -> MenuContent

    @State private var menuOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cardHeight: CGFloat { cardWidth * 1.5 }

    var body: some View {
        ZStack {
            LocalCoverImage(
                url: book.coverURL,
                fallbackTitle: book.title,
                fallbackAuthor: book.authors.first
            )

            if isSelected {
                overlay
                    .transition(.opacity)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 0.5)
        )
        .softShadow(elevated: isSelected)
        .scaleEffect(scaleAmount)
        .animation(reduceMotion ? .easeOut(duration: 0.16) : .spring(duration: 0.32, bounce: 0.20), value: isSelected)
    }

    private var scaleAmount: CGFloat {
        if reduceMotion { return 1.0 }
        return isSelected ? 1.014 : 1.0
    }

    // MARK: - Selected overlay
    //
    // Backdrop-blur of the cover + dark tint. White typography always.
    // Readability is guaranteed by the tint, not by adapting to the cover.
    private var overlay: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(.ultraThinMaterial)

            Color.black.opacity(0.30)

            VStack(alignment: .leading, spacing: 3) {
                Text(book.title)
                    .font(.system(size: cardWidth < 170 ? 13 : 14, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(book.authors.first ?? "Unknown")
                    .font(.system(size: cardWidth < 170 ? 11 : 12, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack {
                HStack {
                    Spacer()
                    moreButton
                }
                Spacer()
            }
            .padding(Theme.Spacing.sm + 2)
        }
    }

    /// Native macOS Menu leaks an indicator chevron despite `.menuIndicator(.hidden)`,
    /// so we use a Button + popover. The popover content uses `MenuRowStyle`
    /// for native-menu-feeling rows in app colors.
    private var moreButton: some View {
        Button {
            menuOpen.toggle()
        } label: {
            ZStack {
                Circle().fill(.ultraThinMaterial)
                Circle().fill(Color.black.opacity(0.55))
                Icon(symbol: .dotsThree, weight: .bold, size: 14)
                    .foregroundStyle(Color.white)
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("More options")
        .popover(isPresented: $menuOpen, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                menu()
            }
            .menuPopoverContainer()
        }
    }
}
