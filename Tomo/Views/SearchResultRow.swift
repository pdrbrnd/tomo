import SwiftUI

/// One row in the search results list. Shared template for library + source
/// results; the right-hand action slot is the only piece that branches.
///
/// The row front-loads the metadata that's discriminating during a search
/// — year, format, language, size — so the user can scan without opening
/// the inspector. Covers are still present (left thumbnail) so the visual
/// continuity with the library grid is preserved.
struct SearchResultRow: View {
    let item: LibraryItem
    let isSelected: Bool
    var deviceStatus: BookCardDeviceStatus = .noDevice
    var downloadState: CardDownloadState = .idle
    /// Source rows: true when a library book already matches this result.
    /// Replaces the "Get" button with an "In library" indicator.
    var isDuplicateInLibrary: Bool = false
    let onSelect: () -> Void
    let onActivate: () -> Void
    var onDownload: (() -> Void)? = nil
    var onCancelDownload: (() -> Void)? = nil

    @State private var isHovering: Bool = false
    @State private var isHoveringCancel: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Wider/taller thumb than a typical list row. Three text lines + a gap
    /// look anaemic against a tiny thumbnail; the larger cover anchors the
    /// row and reads as "this is a book, not a directory entry."
    private static let thumbWidth: CGFloat = 52
    private static var thumbHeight: CGFloat { thumbWidth * Theme.Library.bookHeightMultiplier }
    private static let rowVerticalPadding: CGFloat = 10
    private static let rowHorizontalPadding: CGFloat = 12

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            thumb
            VStack(alignment: .leading, spacing: 0) {
                title
                if !identityParts.isEmpty {
                    Spacer().frame(height: 3)
                    identityLine
                }
                if !technicalParts.isEmpty {
                    // Flexible spacer so the technical line hugs the bottom
                    // of the row regardless of how tall the row ends up
                    // (driven by the thumb). Minimum 6pt keeps a visible
                    // gap even when the row is unusually short.
                    Spacer(minLength: 6)
                    technicalLine
                }
            }
            // Match the thumb's height so the trailing Spacer above has
            // somewhere to grow into — without this the VStack hugs its
            // content and the technical line packs immediately under the
            // identity line.
            .frame(minHeight: Self.thumbHeight, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            actionSlot
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.vertical, Self.rowVerticalPadding)
        .padding(.horizontal, Self.rowHorizontalPadding)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onActivate() }
        .onTapGesture(count: 1) { onSelect() }
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.18), value: isSelected)
        .animation(.easeInOut(duration: 0.14), value: isHovering)
    }

    // MARK: - Thumb

    private var thumb: some View {
        LocalCoverImage(
            url: item.coverURL,
            fallbackTitle: item.title,
            fallbackAuthor: item.firstAuthor
        )
        .frame(width: Self.thumbWidth, height: Self.thumbHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.cover, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 0.5)
        )
        .opacity(deviceStatus == .missingFromDevice ? 0.5 : 1.0)
    }

    // MARK: - Title + meta

    private var title: some View {
        Text(item.title)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(.primary.opacity(Theme.Text.primary))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// First meta line — "identity" facts the user matches against in their
    /// head: who wrote it, when, in what format.
    private var identityLine: some View {
        Text(identityParts.joined(separator: " · "))
            .font(.system(size: 11.5))
            .foregroundStyle(.primary.opacity(Theme.Text.muted))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// Second meta line — "technical" facts the user uses to pick between
    /// duplicates: publisher (where available), language, file size.
    private var technicalLine: some View {
        Text(technicalParts.joined(separator: " · "))
            .font(.system(size: 11))
            .foregroundStyle(.primary.opacity(Theme.Text.tertiary))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var identityParts: [String] {
        var parts: [String] = []
        if let author = item.firstAuthor, !author.isEmpty {
            parts.append(author)
        }
        if let year = item.year {
            parts.append(String(year))
        }
        if let format = item.format {
            parts.append(format)
        }
        return parts
    }

    private var technicalParts: [String] {
        var parts: [String] = []
        if let publisher = item.publisher {
            parts.append(publisher)
        }
        if let localeTag = item.localeTag {
            parts.append(Self.localeDisplay(for: localeTag))
        }
        if let bytes = item.sizeBytes, bytes > 0 {
            parts.append(Self.formatSize(bytes))
        }
        return parts
    }

    private static func localeDisplay(for tag: String) -> String {
        Locale.current.localizedString(forIdentifier: tag) ?? tag
    }

    private static func formatSize(_ bytes: Int) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useKB, .useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: Int64(bytes))
    }

    // MARK: - Action slot

    @ViewBuilder
    private var actionSlot: some View {
        switch item {
        case .book:
            // Library rows: no primary action — the row click selects, the
            // context menu / inspector covers the rest. Empty slot keeps the
            // grid lined up across rows.
            Color.clear.frame(width: 1, height: 1)
        case .source:
            sourceAction
        }
    }

    @ViewBuilder
    private var sourceAction: some View {
        switch downloadState {
        case .idle:
            if isDuplicateInLibrary {
                HStack(spacing: 4) {
                    Icon(symbol: "checkmark.circle.fill", weight: .regular, size: 11)
                        .foregroundStyle(.primary.opacity(Theme.Text.muted))
                    Text("In library")
                        .font(.system(size: 11.5, weight: .regular))
                        .foregroundStyle(.primary.opacity(Theme.Text.muted))
                }
            } else if let onDownload {
                Button(action: onDownload) {
                    Text("Get")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Capsule(style: .continuous).fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .help("Download to library")
            }
        case .downloading(let progress):
            downloadProgressCapsule(progress: progress)
        case .importing:
            statusCapsule(symbol: "arrow.down", label: "Adding…")
        case .added:
            statusCapsule(symbol: "checkmark", label: "Added")
        case .error:
            statusCapsule(symbol: "exclamationmark.triangle.fill", label: "Failed", tone: .error)
        }
    }

    @ViewBuilder
    private func downloadProgressCapsule(progress: Double?) -> some View {
        let capsuleBody = HStack(spacing: 6) {
            Image(systemName: (onCancelDownload != nil && isHoveringCancel) ? "xmark" : "arrow.down")
                .font(.system(size: 10, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
            Text(progressLabel(progress))
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(Color(white: 0.16, opacity: 0.92)))
        .clipShape(Capsule(style: .continuous))

        if let onCancelDownload {
            Button(action: onCancelDownload) {
                capsuleBody
            }
            .buttonStyle(.plain)
            .onHover { isHoveringCancel = $0 }
            .help("Cancel download")
        } else {
            capsuleBody
        }
    }

    private func progressLabel(_ progress: Double?) -> String {
        guard let progress else { return "Downloading" }
        return "\(Int(progress * 100))%"
    }

    private enum StatusTone { case neutral, error }

    private func statusCapsule(symbol: String, label: String, tone: StatusTone = .neutral) -> some View {
        let fill: Color =
            tone == .error
            ? Color(red: 0.78, green: 0.22, blue: 0.18)
            : Color(white: 0.16, opacity: 0.92)
        return HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(fill))
        .clipShape(Capsule(style: .continuous))
    }

    // MARK: - Background

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.sidebarRow, style: .continuous)
            .fill(rowFill)
    }

    private var rowFill: Color {
        if isSelected { return .primary.opacity(Theme.Surface.selected) }
        if isHovering { return .primary.opacity(Theme.Surface.hoverSoft) }
        return .clear
    }
}
