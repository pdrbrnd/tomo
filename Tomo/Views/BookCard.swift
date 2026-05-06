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
/// Selected overlay, scale-up, fallback typography are identical across
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
        return false
    }

    var body: some View {
        ZStack {
            LocalCoverImage(
                url: item.coverURL,
                fallbackTitle: item.title,
                fallbackAuthor: item.firstAuthor,
                isLoading: isCoverLoading
            )
            .opacity(coverDimmed ? 0.45 : 1.0)
            .animation(.easeInOut(duration: 0.18), value: coverDimmed)

            if isSelected {
                selectedOverlay
                    .transition(.opacity)
            }

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
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 0.5)
        )
        .softShadow(elevated: isSelected || downloadState != .idle)
        .scaleEffect(scaleAmount)
        .animation(reduceMotion ? .easeOut(duration: 0.16) : .spring(duration: 0.32, bounce: 0.20), value: isSelected)
        .animation(reduceMotion ? .easeOut(duration: 0.18) : .snappy(duration: 0.32), value: downloadState)
    }

    private var scaleAmount: CGFloat {
        if reduceMotion { return 1.0 }
        return isSelected ? 1.014 : 1.0
    }

    // MARK: - Selected overlay
    //
    // Backdrop-blur of the cover + dark tint. White typography always.
    // Readability is guaranteed by the tint, not by adapting to the cover.
    // Author treatment matches the rest-state coverless fallback (uppercase,
    // tracked, 10pt) so the card reads consistent across all four cells of
    // the {cover, no-cover} × {selected, rest} matrix.
    private var selectedOverlay: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(.ultraThinMaterial)

            Color.black.opacity(0.30)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(item.firstAuthor ?? "Unknown")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .lineLimit(2)
                    .tracking(0.1)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
