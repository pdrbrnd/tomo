import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Search-bar trailing button: opens a popover for managing source plugins.
/// Visual language matches the right-click context menu — same `MenuRowStyle`,
/// same edge-to-edge dividers, same icon-column indent.
struct SourcesSettingsButton: View {
    let state: AppState
    @State private var popoverOpen = false

    var body: some View {
        Button {
            popoverOpen.toggle()
        } label: {
            Icon(symbol: "ellipsis", weight: .regular, size: 11)
                .foregroundStyle(.primary.opacity(popoverOpen ? Theme.Text.primary : Theme.Text.placeholder))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if state.hasUnacknowledgedPluginUpdates {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .offset(x: 4, y: 0)
                    }
                }
        }
        .buttonStyle(.plain)
        .help("Sources")
        .popover(isPresented: $popoverOpen, arrowEdge: .top) {
            SourcesPopoverContent(state: state, popoverOpen: $popoverOpen)
                .onAppear { state.acknowledgePluginUpdatesBadge() }
        }
    }
}

/// Search-bar trailing button: clears the search. Takes over the trailing
/// slot from `SourcesSettingsButton` whenever the search field has text —
/// the X is the only visible "click to escape search" affordance, which
/// matters more in that context than 1-click sources access. Uses
/// `xmark.circle.fill` to match macOS's native search-field clear glyph.
struct ClearSearchButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Icon(symbol: "xmark.circle.fill", weight: .regular, size: 13)
                .foregroundStyle(
                    .primary.opacity(hovered ? Theme.Text.primary : Theme.Text.secondary)
                )
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Clear search")
        .onHover { hovered = $0 }
    }
}

private struct SourcesPopoverContent: View {
    let state: AppState
    @Binding var popoverOpen: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if state.pluginSources.isEmpty {
                emptyRow
            } else {
                ForEach(state.pluginSources) { plugin in
                    pluginRow(plugin: plugin)
                }
            }

            MenuDivider()

            if state.hasPluginUpdates {
                Button {
                    popoverOpen = false
                    Task { await state.updateAllAvailablePlugins() }
                } label: {
                    HStack(spacing: 9) {
                        Icon(symbol: "arrow.down.circle", weight: .regular, size: 13)
                            .frame(width: 14)
                        Text("Update Plugins")
                        Spacer(minLength: 8)
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                    }
                }
            }
            Button {
                openPluginsSettings()
            } label: {
                rowLabel(icon: "puzzlepiece.extension", title: "Manage Plugins…")
            }
            Button {
                installPlugin()
            } label: {
                rowLabel(icon: "plus", title: "Install Plugin…")
            }
            Button {
                revealPluginsFolder()
            } label: {
                rowLabel(icon: "folder", title: "Reveal Plugins Folder")
            }
            if !state.pluginSources.isEmpty {
                Button {
                    Task { await state.reloadPluginSource() }
                } label: {
                    rowLabel(icon: "arrow.clockwise", title: "Reload")
                }
            }
        }
        .menuPopoverContainer(minWidth: 240)
    }

    private func openPluginsSettings() {
        // Set the section before `openWindow` so cold-open `onAppear` sees it.
        state.pendingSettingsSection = SettingsSection.plugins.rawValue
        popoverOpen = false
        openWindow(id: TomoApp.settingsWindowID)
    }

    /// Section header — uppercase secondary text, indented to match the
    /// menu rows below so everything reads on the same vertical edge.
    private var header: some View {
        Text("Sources")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary.opacity(Theme.Text.placeholder))
            .tracking(0.2)
            .textCase(.uppercase)
            .padding(.horizontal, Theme.Spacing.menuInset + 12)
            .padding(.bottom, 4)
    }

    /// One plugin row with a per-plugin enable checkbox. Lays out on the
    /// same indent as the menu rows: leading icon-column slot (filled by
    /// the toggle), then the plugin name + subtitle.
    private func pluginRow(plugin: PluginSource) -> some View {
        HStack(spacing: 9) {
            Toggle(
                "",
                isOn: Binding(
                    get: { state.enabledPluginIDs.contains(plugin.id) },
                    set: { state.setPluginEnabled(plugin.id, enabled: $0) }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(plugin.displayName)
                    .font(.system(size: 13, weight: .regular))
                Text("Plugin")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .padding(.horizontal, Theme.Spacing.menuInset)
    }

    private var emptyRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("No plugins installed")
                .font(.system(size: 13, weight: .regular))
            Text("Drop a .js file in the plugins folder to enable source search.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .padding(.horizontal, Theme.Spacing.menuInset)
    }

    /// Matches the icon+title layout used by `bookMenuItem` so the rows
    /// here line up exactly with the right-click context menu's rows.
    private func rowLabel(icon: String, title: String) -> some View {
        HStack(spacing: 9) {
            Icon(symbol: icon, weight: .regular, size: 13)
                .frame(width: 14)
            Text(title)
        }
    }

    private func installPlugin() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.javaScript, UTType(filenameExtension: "js") ?? UTType.javaScript]
        panel.prompt = "Install"
        panel.message = "Choose a plugin .js file."
        if CrashReporter.runModal(panel) == .OK, let url = panel.url {
            Task { await state.installPlugin(from: url) }
        }
    }

    private func revealPluginsFolder() {
        guard let dir = PluginDirectory.directoryURL() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}
