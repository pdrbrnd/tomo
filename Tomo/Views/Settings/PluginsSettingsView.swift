import AppKit
import SwiftUI

/// Settings → Plugins: Installed / Browse / Registries.
struct PluginsSettingsView: View {
    @Bindable var state: AppState

    @State private var newRegistryURL: String = ""
    @State private var addingRegistry: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topActions

            section(title: "Installed", helper: nil) {
                if state.pluginSources.isEmpty {
                    emptyRow("No plugins installed.")
                } else {
                    ForEach(state.pluginSources) { plugin in
                        installedRow(plugin: plugin)
                    }
                }
            }

            section(title: "Browse", helper: nil) {
                if browsableEntries.isEmpty {
                    emptyRow(
                        state.cachedRegistries.isEmpty
                            ? "Click \u{201C}Check for updates\u{201D} to load registries."
                            : "Everything from your registries is already installed."
                    )
                } else {
                    ForEach(browsableEntries, id: \.entry.id) { item in
                        browseRow(item: item)
                    }
                }
            }

            section(title: "Registries", helper: registriesHelper) {
                registriesRow(
                    name: cachedRegistryName(for: state.defaultRegistryURL)
                        ?? "Tomo Official Plugins",
                    url: state.defaultRegistryURL,
                    canRemove: false
                )
                ForEach(state.userAddedRegistryURLs, id: \.self) { url in
                    registriesRow(
                        name: cachedRegistryName(for: url) ?? url.host ?? url.absoluteString,
                        url: url,
                        canRemove: true
                    )
                }
                addRegistryRow
            }
        }
    }

    // MARK: - Top actions

    private var topActions: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button {
                Task { await state.refreshAllRegistries() }
            } label: {
                HStack(spacing: 6) {
                    if state.pluginRegistryRefreshInFlight {
                        ProgressView().controlSize(.mini)
                    } else {
                        Icon(symbol: "arrow.clockwise", weight: .regular, size: 12)
                    }
                    Text("Check for updates")
                }
            }
            .controlSize(.small)
            .disabled(state.pluginRegistryRefreshInFlight)

            if state.hasPluginUpdates {
                Text(
                    "\(state.pluginUpdatesAvailable.count) update\(state.pluginUpdatesAvailable.count == 1 ? "" : "s") available"
                )
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(Theme.Text.secondary))
            }

            Spacer()
        }
        .padding(.vertical, Theme.Spacing.sm)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    // MARK: - Installed

    private func installedRow(plugin: PluginSource) -> some View {
        let origin = state.registryOrigin(for: plugin)
        let updateAvailable = state.pluginUpdatesAvailable.contains(plugin.id)
        let updateTarget = updateAvailable ? state.latestRegistryEntry(forID: plugin.id) : nil

        return HStack(spacing: Theme.Spacing.md) {
            Toggle(
                "",
                isOn: Binding(
                    get: { state.enabledPluginIDs.contains(plugin.id) },
                    set: { state.setPluginEnabled(plugin.id, enabled: $0) }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.displayName)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary.opacity(Theme.Text.primary))
                Text(statusLine(plugin: plugin, origin: origin, updateAvailable: updateAvailable))
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(Theme.Text.secondary))
            }

            Spacer()

            if updateTarget != nil {
                Button("Update") {
                    Task { await state.applyPluginUpdate(id: plugin.id) }
                }
                .controlSize(.small)
            }

            Button(role: .destructive) {
                Task { await state.removeInstalledPlugin(id: plugin.id) }
            } label: {
                Text("Remove")
            }
            .controlSize(.small)
        }
        .padding(.vertical, Theme.Spacing.sm)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    private func statusLine(
        plugin: PluginSource,
        origin: (entry: PluginRegistryEntry, registryURL: URL)?,
        updateAvailable: Bool
    ) -> String {
        if plugin.manifest == nil {
            return "Manifest missing — registry features unavailable."
        }
        if updateAvailable {
            return "Update available"
        }
        if let origin {
            return "Updated \(formatRegistryDate(origin.entry.version))"
        }
        return "User-supplied"
    }

    // MARK: - Browse

    private struct BrowseItem {
        let entry: PluginRegistryEntry
        let registryURL: URL
        let registryName: String
    }

    private var browsableEntries: [BrowseItem] {
        let installedIDs = Set(state.pluginSources.map(\.id))
        var items: [BrowseItem] = []
        var seen: Set<String> = []
        for url in state.allRegistryURLs {
            guard let cached = state.cachedRegistries[url] else { continue }
            for entry in cached.registry.plugins {
                if installedIDs.contains(entry.id) { continue }
                if !seen.insert(entry.id).inserted { continue }
                items.append(
                    BrowseItem(entry: entry, registryURL: url, registryName: cached.registry.name)
                )
            }
        }
        return items.sorted { $0.entry.name.localizedCaseInsensitiveCompare($1.entry.name) == .orderedAscending }
    }

    private func browseRow(item: BrowseItem) -> some View {
        let compatible = state.isCompatible(entry: item.entry)
        return HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.entry.name)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary.opacity(Theme.Text.primary))
                Text(browseSubtitle(item: item, compatible: compatible))
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(Theme.Text.secondary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button("Install") {
                Task { await state.installPluginFromRegistry(item.entry, from: item.registryURL) }
            }
            .controlSize(.small)
            .disabled(!compatible)
        }
        .padding(.vertical, Theme.Spacing.sm)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    private func browseSubtitle(item: BrowseItem, compatible: Bool) -> String {
        if !compatible, let min = item.entry.minAppVersion {
            return "Requires Tomo \(min)+ — you have \(AppVersion.current)"
        }
        let base = item.entry.description ?? "From \(item.registryName)"
        return "\(base) • Updated \(formatRegistryDate(item.entry.version))"
    }

    // MARK: - Registries

    private var registriesHelper: String {
        "Tomo only ever lists legitimate sources in its official registry. "
            + "You can add third-party registries here — at your own discretion."
    }

    private func registriesRow(name: String, url: URL, canRemove: Bool) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary.opacity(Theme.Text.primary))
                Text(url.absoluteString)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.primary.opacity(Theme.Text.tertiary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if canRemove {
                Button(role: .destructive) {
                    state.removeUserRegistry(url)
                } label: {
                    Text("Remove")
                }
                .controlSize(.small)
            } else {
                Text("Pinned")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(Theme.Text.tertiary))
            }
        }
        .padding(.vertical, Theme.Spacing.sm)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    private var addRegistryRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            TextField("https://your-registry.example.com", text: $newRegistryURL)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .disabled(addingRegistry)
                .onSubmit(submitAddRegistry)

            Button {
                submitAddRegistry()
            } label: {
                if addingRegistry {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("Add Registry")
                }
            }
            .controlSize(.small)
            .disabled(addingRegistry || URL(string: newRegistryURL.trimmingCharacters(in: .whitespaces)) == nil)
        }
        .padding(.vertical, Theme.Spacing.sm)
    }

    private func submitAddRegistry() {
        let trimmed = newRegistryURL.trimmingCharacters(in: .whitespaces)
        guard var url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            state.showToast(.error("Enter a full https:// URL."))
            return
        }
        // Accept either the bare host (https://foo.pages.dev) or the full
        // path. If the URL doesn't already end in `registry.json`, append it
        // — the registry filename is convention, not something the user
        // should have to remember.
        if url.lastPathComponent != "registry.json" {
            url = url.appending(path: "registry.json")
        }
        addingRegistry = true
        Task {
            await state.addUserRegistry(url)
            addingRegistry = false
            newRegistryURL = ""
        }
    }

    // MARK: - Date formatting

    /// Falls back to the raw string when the version isn't a recognizable
    /// ISO-8601 timestamp.
    private func formatRegistryDate(_ versionString: String) -> String {
        if let date = Self.isoFormatter.date(from: versionString) {
            return Self.displayFormatter.string(from: date)
        }
        return versionString
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    // MARK: - Lookups

    private func cachedRegistryName(for url: URL?) -> String? {
        guard let url, let cached = state.cachedRegistries[url] else { return nil }
        return cached.registry.name
    }

    // MARK: - Section scaffolding

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        helper: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary.opacity(Theme.Text.secondary))
                .tracking(0.2)
                .textCase(.uppercase)
                .padding(.top, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.xs)

            content()

            if let helper {
                Text(helper)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(Theme.Text.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Spacing.sm)
            }
        }
    }

    private func emptyRow(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.primary.opacity(Theme.Text.secondary))
            .padding(.vertical, Theme.Spacing.sm)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
            }
    }
}
