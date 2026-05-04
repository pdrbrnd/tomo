import SwiftUI

/// Book card: cover at rest, backdrop-blurred dark overlay with title +
/// author when selected. Pure presentation — the parent wires single/double
/// tap and the right-click menu.
///
/// Tri-state device relation for a card. Mutually exclusive: a book on
/// the device gets the check badge, one missing gets the cover dim, and
/// without a device neither applies.
enum BookCardDeviceStatus {
    case noDevice
    case onDevice
    case missingFromDevice
}

struct BookCard: View {
    let book: Book
    let isSelected: Bool
    /// See `BookCardDeviceStatus`. Dim is applied surgically to the cover —
    /// `.opacity()` on the whole card breaks the selection overlay's
    /// `.ultraThinMaterial` backdrop blur (the modifier rasterizes the
    /// layer and kills Material's window-backdrop sampling).
    var deviceStatus: BookCardDeviceStatus = .noDevice
    let cardWidth: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cardHeight: CGFloat { cardWidth * 1.5 }
    private var isDimmed: Bool { deviceStatus == .missingFromDevice }
    private var showsOnDeviceBadge: Bool { deviceStatus == .onDevice }

    var body: some View {
        ZStack {
            LocalCoverImage(
                url: book.coverURL,
                fallbackTitle: book.title,
                fallbackAuthor: book.authors.first
            )
            .opacity(isDimmed ? 0.45 : 1.0)
            .animation(.easeInOut(duration: 0.18), value: isDimmed)

            if isSelected {
                overlay
                    .transition(.opacity)
            }

            if showsOnDeviceBadge {
                VStack {
                    HStack {
                        onDeviceBadge
                        Spacer()
                    }
                    Spacer()
                }
                .padding(Theme.Spacing.sm + 2)
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
        }
    }

    /// Subtle blurred check pill at the top-left of cards whose book is on
    /// the connected device. Pairs with the cover dim on missing books —
    /// together they give a clear positive/negative signal at a glance.
    private var onDeviceBadge: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().fill(Color.black.opacity(0.62))
            Icon(symbol: "checkmark", weight: .bold, size: 9)
                .foregroundStyle(Color.white)
        }
        .frame(width: 18, height: 18)
        .help("On device")
    }
}
