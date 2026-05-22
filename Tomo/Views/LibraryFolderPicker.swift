import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Folder pill rendered next to the traffic lights — the always-visible
/// affordance for "what library is this?" and "switch / open another".
/// Replaces the old Settings pane: with one knob, a dedicated pane is
/// dead weight; an inline pill is both the indicator and the entry point.
///
/// Pattern follows Zed's project-switcher: current folder name + chevron,
/// click to reveal recents and an "open folder" escape hatch. No search
/// field — recents capped at 8 (see `LibraryFolder`); a list scans faster
/// than typing for that count.
struct LibraryFolderPicker: View {
    let folder: URL?
    let setFolder: (URL) -> Void
    let clearFolder: () -> Void

    @State private var popoverOpen = false
    @State private var fileImporterOpen = false
    @State private var hoveredRecent: URL?
    /// Bumped after a removal so SwiftUI re-evaluates `popoverContent` and
    /// re-reads `LibraryFolder.recents()`. The recents list lives in
    /// UserDefaults and is otherwise invisible to the view-tree dependency
    /// tracker.
    @State private var recentsTick = 0

    var body: some View {
        Button {
            popoverOpen.toggle()
        } label: {
            pillLabel
        }
        .buttonStyle(.plain)
        .help(folder?.path(percentEncoded: false) ?? "Choose a library folder")
        .popover(isPresented: $popoverOpen, arrowEdge: .top) {
            popoverContent
                .menuPopoverContainer()
        }
        .fileImporter(
            isPresented: $fileImporterOpen,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                setFolder(url)
            }
        }
    }

    private var pillLabel: some View {
        HStack(spacing: 6) {
            Icon(symbol: "folder", weight: .regular, size: 11)
                .foregroundStyle(.primary.opacity(Theme.Text.muted))
            Text(folder?.lastPathComponent ?? "Choose folder...")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(Theme.Text.primary))
                .lineLimit(1)
            Icon(symbol: "chevron.down", weight: .semibold, size: 8)
                .foregroundStyle(.primary.opacity(Theme.Text.tertiary))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.menuItem, style: .continuous)
                .fill(Theme.overlaySurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.menuItem, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 0.5)
        )
        .softShadow(elevated: false)
    }

    @ViewBuilder
    private var popoverContent: some View {
        // Read `recentsTick` so SwiftUI re-evaluates this body when a
        // remove fires; `LibraryFolder.recents()` reads UserDefaults and
        // would otherwise be invisible to the dependency tracker.
        let _ = recentsTick
        let recents = LibraryFolder.recents()

        VStack(alignment: .leading, spacing: 0) {
            ForEach(recents, id: \.self) { url in
                recentRow(url)
            }
            if !recents.isEmpty {
                MenuDivider()
            }
            openFolderRow
        }
    }

    private func recentRow(_ url: URL) -> some View {
        let isCurrent = url.standardizedFileURL == folder?.standardizedFileURL
        let isHovered = hoveredRecent == url
        return Button {
            popoverOpen = false
            if !isCurrent { setFolder(url) }
        } label: {
            HStack(spacing: 9) {
                Icon(symbol: "folder", weight: .regular, size: 13)
                    .frame(width: 14)
                Text(url.lastPathComponent)
                Spacer()
                trailingSlot(url: url, isCurrent: isCurrent, isHovered: isHovered)
            }
        }
        .onHover { hovering in
            hoveredRecent = hovering ? url : (hoveredRecent == url ? nil : hoveredRecent)
        }
    }

    /// Single trailing slot for each recent row. Hover swaps the checkmark
    /// (if current) for two action icons. Instant — no animation.
    @ViewBuilder
    private func trailingSlot(url: URL, isCurrent: Bool, isHovered: Bool) -> some View {
        if isHovered {
            HStack(spacing: 6) {
                rowActionButton(symbol: "magnifyingglass", help: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    popoverOpen = false
                }
                rowActionButton(symbol: "trash", help: "Remove from Recents") {
                    removeRecent(url)
                }
            }
        } else if isCurrent {
            Icon(symbol: "checkmark", weight: .medium, size: 11)
                .foregroundStyle(.primary.opacity(0.5))
        }
    }

    private func rowActionButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(symbol: symbol, weight: .regular, size: 11)
                .foregroundStyle(.primary.opacity(Theme.Text.muted))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func removeRecent(_ url: URL) {
        let isCurrent = url.standardizedFileURL == folder?.standardizedFileURL
        LibraryFolder.removeFromRecents(url)
        hoveredRecent = nil
        recentsTick &+= 1
        if isCurrent {
            // Removing the active library returns the user to the empty
            // state; close the popover so the centered CTA is unobstructed.
            clearFolder()
            popoverOpen = false
        }
    }

    private var openFolderRow: some View {
        Button {
            popoverOpen = false
            // Defer until after the popover dismisses — fileImporter and
            // popover both want the window's modal stack and overlap badly.
            Task { @MainActor in
                fileImporterOpen = true
            }
        } label: {
            HStack(spacing: 9) {
                Icon(symbol: "folder.badge.plus", weight: .regular, size: 13)
                    .frame(width: 14)
                Text("Open Folder…")
            }
        }
    }
}
