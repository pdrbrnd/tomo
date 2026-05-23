import SwiftUI

/// Settings window — fully custom, mirrors the library window's chrome
/// (hidden title bar, rounded sidebar pane on a dark canvas) but the
/// detail content sits directly on the canvas without its own card. The
/// sidebar still gets the full pane treatment so it reads as a distinct
/// region; the detail is breathing space + content.
struct SettingsRoot: View {
    let state: AppState
    @State private var selection: SettingsSection = .languages

    private static let sidebarWidth: CGFloat = 232
    private static let paneInset: CGFloat = Theme.Chrome.paneInset
    /// Fixed window dimensions. Settings isn't resizable.
    static let windowWidth: CGFloat = 760
    static let windowHeight: CGFloat = 520

    var body: some View {
        HStack(spacing: 0) {
            sidebarPane
                .frame(width: Self.sidebarWidth)
                .zIndex(1)

            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea(.all)
        .background(Theme.canvas)
        .background(WindowCustomizer())
        .frame(width: Self.windowWidth, height: Self.windowHeight)
        .onAppear { applyPendingSection() }
        .onChange(of: state.pendingSettingsSection) { _, _ in applyPendingSection() }
    }

    /// Honours `AppState.pendingSettingsSection` so other surfaces (e.g.
    /// the sources popover's "Manage Plugins…" row) can open the window
    /// pre-routed to a specific section. Cleared after applying so the
    /// next bare open lands on the default.
    private func applyPendingSection() {
        guard let raw = state.pendingSettingsSection,
            let section = SettingsSection(rawValue: raw)
        else { return }
        selection = section
        state.pendingSettingsSection = nil
    }

    // MARK: - Sidebar pane

    private var sidebarPane: some View {
        SettingsSidebar(selection: $selection)
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 0.5)
            )
            .paneShadow()
            .padding(Self.paneInset)
    }

    // MARK: - Detail (no card; content sits on the canvas)

    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text(selection.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary.opacity(Theme.Text.emphatic))
                    .padding(.top, Theme.Spacing.lg)

                detail(for: selection)
            }
            .padding(.top, Theme.Spacing.lg)
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func detail(for section: SettingsSection) -> some View {
        switch section {
        case .languages:
            LanguageSettingsView(state: state)
        case .plugins:
            PluginsSettingsView(state: state)
        case .privacy:
            PrivacySettingsView()
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case languages
    case plugins
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .languages: "Languages"
        case .plugins: "Plugins"
        case .privacy: "Privacy"
        }
    }

    var symbol: String {
        switch self {
        case .languages: "character.bubble"
        case .plugins: "puzzlepiece.extension"
        case .privacy: "hand.raised"
        }
    }
}
