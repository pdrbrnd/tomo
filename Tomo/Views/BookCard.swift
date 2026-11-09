import AppKit
import SwiftUI

/// Card body shared by library books and source-search results. Pure
/// presentation — the parent wires gestures, drag, context menu, and
/// selection state.
///
/// One body, two kinds of items:
/// - `.book(_)` cards optionally render an on-device check badge and dim
///   when the book is missing from the connected device.
/// - `.source(_)` cards render an idle cloud-download badge at rest, and a
///   floating state capsule (DeviceTile-shaped) while a download is in
///   flight.
///
/// Selection ring and fallback typography are identical across
/// both kinds.
enum BookCardDeviceStatus {
    case noDevice
    case onDevice
    case missingFromDevice
}

/// Per-source-card download state. Drives the in-place capsule morph.
/// Book cards always get `.idle`.
enum CardDownloadState: Equatable {
    case idle
    case downloading(progress: Double?)
    case importing
    case added
    case error
}

struct BookCard: View {
    let item: LibraryItem
    let isSelected: Bool
    var dimmedBySelection = false
    var deviceStatus: BookCardDeviceStatus = .noDevice
    var downloadState: CardDownloadState = .idle
    /// Forwarded to `LocalCoverImage` so source-result cards show a
    /// skeleton pulse while a plugin search / cover enricher is still
    /// running, even before a `coverURL` lands.
    var isCoverLoading: Bool = false
    let cardWidth: CGFloat
    /// When set on a `.source` card, the idle cloud badge becomes a
    /// button that triggers this directly. People kept clicking the
    /// badge expecting download — the badge looks like a button, so it
    /// is one.
    var onSourceDownload: (() -> Void)? = nil
    /// When set and the card is in a `.downloading` state, the capsule
    /// becomes a cancel target — hovering swaps the down-arrow icon for
    /// an xmark and clicking calls this.
    var onCancelDownload: (() -> Void)? = nil
    /// Source cards: a preview download is in flight. Shows an "Opening…"
    /// capsule. Kept separate from `downloadState` (which drives the Get →
    /// added morph) so a non-committal preview never removes the card.
    var isPreviewing: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHoveringCancel: Bool = false

    private var cardHeight: CGFloat { cardWidth * Theme.Library.bookHeightMultiplier }
    private var isDimmed: Bool { deviceStatus == .missingFromDevice }
    private var showsOnDeviceBadge: Bool {
        if case .book = item { return deviceStatus == .onDevice }
        return false
    }
    private var showsIdleSourceBadge: Bool {
        item.isSource && downloadState == .idle
    }
    private var coverDimmed: Bool {
        if isDimmed { return true }
        if item.isSource && downloadState != .idle { return true }
        if item.isSource && isPreviewing { return true }
        return false
    }

    var body: some View {
        ZStack {
            LocalCoverImage(
                url: item.coverURL,
                fallbackTitle: item.title,
                fallbackAuthor: item.firstAuthor,
                isLoading: isCoverLoading,
                cacheID: item.id
            )
            .opacity(coverDimmed ? 0.45 : 1.0)
            .animation(.easeInOut(duration: 0.18), value: coverDimmed)

            // Top-left badge slot. Mutually exclusive: on-device check for
            // library books on the device, or idle cloud for source items
            // at rest.
            if showsOnDeviceBadge {
                topLeadingBadge { onDeviceBadge }
            } else if showsIdleSourceBadge {
                topLeadingBadge { idleSourceBadge }
            }

            if item.isSource && downloadState != .idle {
                stateCapsule
                    .transition(
                        .move(edge: .bottom)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.92))
                    )
            } else if item.isSource && isPreviewing {
                previewingCapsule
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 0.5)
        )
        .softShadow(elevated: downloadState != .idle)
        .opacity(dimmedBySelection ? 0.65 : 1)
        .animation(.easeOut(duration: 0.16), value: dimmedBySelection)
        .overlay {
            if isSelected {
                SelectedCoverRing()
                    .padding(-SelectedCoverRing.outset)
                    .transition(.identity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(reduceMotion ? .easeOut(duration: 0.18) : .snappy(duration: 0.32), value: downloadState)
        .animation(reduceMotion ? .easeOut(duration: 0.18) : .snappy(duration: 0.32), value: isPreviewing)
    }

    /// "Opening…" capsule shown while a preview download is in flight. Same
    /// DeviceTile shape as `stateCapsule` so the two read as one family.
    private var previewingCapsule: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
                .tint(Color.white)
            Text("Opening…")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(Color(white: 0.16, opacity: 0.92)))
        .clipShape(Capsule(style: .continuous))
        .softShadow(elevated: true)
        .padding(.horizontal, Theme.Spacing.sm)
    }

    // MARK: - Badges

    @ViewBuilder
    private func topLeadingBadge<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            HStack {
                content()
                Spacer()
            }
            Spacer()
        }
        .padding(Theme.Spacing.sm + 2)
        .transition(.opacity)
    }

    /// Blurred device pill at the top-left of cards whose book is on the
    /// connected device. Glyph matches `DeviceTile`'s default icon so the
    /// "this is on the device" signal reads the same wherever it shows up.
    private var onDeviceBadge: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().fill(Color.black.opacity(0.62))
            Icon(symbol: "ipad", weight: .regular, size: 11)
                .foregroundStyle(Color.white)
        }
        .frame(width: 22, height: 22)
        .help("On device")
    }

    /// Idle source-result badge: same pill shape as `onDeviceBadge` so the
    /// visual language stays consistent — different glyph, same placement.
    /// Becomes a button when `onSourceDownload` is provided.
    @ViewBuilder
    private var idleSourceBadge: some View {
        if let onSourceDownload {
            Button(action: onSourceDownload) {
                cloudBadgeShape
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .help("Download to library")
        } else {
            cloudBadgeShape
                .help("From source")
        }
    }

    private var cloudBadgeShape: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().fill(Color.black.opacity(0.62))
            Icon(symbol: "icloud.and.arrow.down", weight: .bold, size: 11)
                .foregroundStyle(Color.white)
        }
        .frame(width: 22, height: 22)
    }

    // MARK: - Source state capsule
    //
    // DeviceTile-shaped morph. Capsule body stays constant across states so
    // SwiftUI can interpolate label, fill, and progress rather than swap.

    @ViewBuilder
    private var stateCapsule: some View {
        if case .downloading = downloadState, let onCancelDownload {
            Button(action: onCancelDownload) {
                stateCapsuleBody
            }
            .buttonStyle(.plain)
            .onHover { isHoveringCancel = $0 }
            .help("Cancel download")
        } else {
            stateCapsuleBody
        }
    }

    private var stateCapsuleBody: some View {
        HStack(spacing: 6) {
            Image(systemName: capsuleSymbol)
                .font(.system(size: 10, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
            Text(capsuleLabel)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .contentTransition(.numericText())
                .id(capsuleLabel)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(capsuleFill))
        .overlay(progressBar)
        .clipShape(Capsule(style: .continuous))
        .softShadow(elevated: true)
        .padding(.horizontal, Theme.Spacing.sm)
    }

    private var capsuleSymbol: String {
        switch downloadState {
        case .idle: return "icloud.and.arrow.down"
        case .downloading:
            // Hover-swap: the capsule itself is the cancel target while
            // downloading, but the affordance only reveals on hover so the
            // resting capsule stays visually about *progress*, not "cancel".
            return (onCancelDownload != nil && isHoveringCancel) ? "xmark" : "arrow.down"
        case .importing: return "checkmark"
        case .added: return "checkmark"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var capsuleLabel: String {
        switch downloadState {
        case .idle: return ""
        case .downloading(let progress):
            if let progress { return "Downloading \(Int(progress * 100))%" }
            return "Downloading"
        case .importing: return "Adding to library"
        case .added: return "Added to library"
        case .error: return "Failed"
        }
    }

    private var capsuleFill: Color {
        switch downloadState {
        case .idle, .downloading, .importing, .added:
            return Color(white: 0.16, opacity: 0.92)
        case .error:
            return Color(red: 0.78, green: 0.22, blue: 0.18)
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if case .downloading(let progress) = downloadState, let progress {
            GeometryReader { geo in
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.32))
                    .frame(width: geo.size.width * CGFloat(min(max(progress, 0), 1)), height: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }
}

/// Draws AppKit's native focus ring for each selected cover while keyboard
/// focus stays on the grid. The extra drawing space keeps the glow unclipped.
private struct SelectedCoverRing: NSViewRepresentable {
    static let outset: CGFloat = 8

    func makeNSView(context: Context) -> RingView { RingView() }
    func updateNSView(_ view: RingView, context: Context) {}

    final class RingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            let mask = NSBezierPath(
                roundedRect: bounds.insetBy(dx: outset, dy: outset),
                xRadius: Theme.Radius.card, yRadius: Theme.Radius.card
            )
            NSGraphicsContext.saveGraphicsState()
            NSFocusRingPlacement.only.set()
            NSColor.black.setFill()
            mask.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
