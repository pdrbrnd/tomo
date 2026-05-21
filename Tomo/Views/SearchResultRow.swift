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
    /// Collections this book belongs to. Library rows render up to a couple
    /// as inline chips; the active collection (if any) is filtered out by
    /// the caller to avoid redundancy with the active scope.
    var bookCollections: [Collection] = []
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

    private static let thumbWidth: CGFloat = 44
    private static var thumbHeight: CGFloat { thumbWidth * Theme.Library.bookHeightMultiplier }
    private static let rowVerticalPadding: CGFloat = 8
    private static let rowHorizontalPadding: CGFloat = 12

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            thumb
            VStack(alignment: .leading, spacing: 3) {
                title
                metaLine
                if !chips.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(chips, id: \.self) { chip in
                            RowChip(label: chip)
                        }
                    }
                    .padding(.top, 2)
                }
            }
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

    private var metaLine: some View {
        Text(metaParts.joined(separator: " · "))
            .font(.system(size: 11.5))
            .foregroundStyle(.primary.opacity(Theme.Text.muted))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var metaParts: [String] {
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

    // MARK: - Chips

    /// Inline chips shown under the meta line. Library rows surface on-device
    /// + collection memberships; source rows currently show nothing (the
    /// section header already names the source).
    private var chips: [String] {
        guard case .book = item else { return [] }
        var out: [String] = []
        if deviceStatus == .onDevice { out.append("On device") }
        out.append(contentsOf: bookCollections.prefix(3).map(\.name))
        if bookCollections.count > 3 {
            out.append("+\(bookCollections.count - 3)")
        }
        return out
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

/// Small text chip rendered inline under the meta line. Visual weight
/// intentionally low — chips are scanning hints, not affordances.
private struct RowChip: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.primary.opacity(Theme.Text.muted))
            .tracking(0.1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(.primary.opacity(Theme.Surface.hoverSoft))
            )
    }
}
