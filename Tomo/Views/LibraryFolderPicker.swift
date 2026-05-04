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

    @State private var popoverOpen = false
    @State private var fileImporterOpen = false

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
            Text(folder?.lastPathComponent ?? "Choose Library…")
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
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.menuItem, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 0.5)
        )
        .softShadow(elevated: false)
    }

    @ViewBuilder
    private var popoverContent: some View {
        // `recents()` is a static read; SwiftUI re-evaluates body when
        // `folder` changes (which is when recents change), so the snapshot
        // stays fresh without observation plumbing.
        let recents = LibraryFolder.recents()

        VStack(alignment: .leading, spacing: 0) {
            ForEach(recents, id: \.self) { url in
                recentRow(url)
            }
            if !recents.isEmpty {
                MenuDivider()
            }
            openFolderRow
            if folder != nil {
                showInFinderRow
            }
        }
    }

    private func recentRow(_ url: URL) -> some View {
        let isCurrent = url.standardizedFileURL == folder?.standardizedFileURL
        return Button {
            popoverOpen = false
            if !isCurrent { setFolder(url) }
        } label: {
            HStack(spacing: 9) {
                Icon(symbol: "folder", weight: .regular, size: 13)
                    .frame(width: 14)
                Text(url.lastPathComponent)
                Spacer()
                if isCurrent {
                    Icon(symbol: "checkmark", weight: .medium, size: 11)
                        .foregroundStyle(.primary.opacity(0.5))
                }
            }
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

    private var showInFinderRow: some View {
        Button {
            popoverOpen = false
            if let folder {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        } label: {
            HStack(spacing: 9) {
                Icon(symbol: "magnifyingglass", weight: .regular, size: 13)
                    .frame(width: 14)
                Text("Show in Finder")
            }
        }
    }
}
