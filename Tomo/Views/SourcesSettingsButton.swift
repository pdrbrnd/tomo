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
            Group {
                if state.pluginSearchInFlight {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.primary.opacity(Theme.Text.placeholder))
                } else {
                    Icon(symbol: "ellipsis", weight: .regular, size: 11)
                        .foregroundStyle(.primary.opacity(popoverOpen ? Theme.Text.primary : Theme.Text.placeholder))
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            // Update-available badge: small dot in the top-right corner of
            // the trailing button. Cleared once the user opens Plugins
            // settings and the update is applied.
            .overlay(alignment: .topTrailing) {
                if state.hasPluginUpdates {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .offset(x: -2, y: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Sources")
        .popover(isPresented: $popoverOpen, arrowEdge: .top) {
            SourcesPopoverContent(state: state, popoverOpen: $popoverOpen)
        }
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

            Button {
                openPluginsSettings()
            } label: {
                rowLabel(
                    icon: "puzzlepiece.extension",
                    title: state.hasPluginUpdates ? "Manage Plugins (updates available)…" : "Manage Plugins…"
                )
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
        // Set the deep-link target *before* opening the window so
        // `SettingsRoot.onAppear` (cold open) or `onChange`
        // (already-open window) picks up the right section.
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
        if panel.runModal() == .OK, let url = panel.url {
            Task { await state.installPlugin(from: url) }
        }
    }

    private func revealPluginsFolder() {
        guard let dir = PluginDirectory.directoryURL() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}
