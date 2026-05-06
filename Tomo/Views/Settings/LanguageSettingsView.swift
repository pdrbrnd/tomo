import AppKit
import SwiftUI

/// Settings → Languages: pick which bundled profiles auto-classify on import.
///
/// Inspector-style layout — full-width rows separated by hairlines, no
/// container card, header row carries a tri-state checkbox that toggles
/// "select all" / "deselect all" with a mixed indicator when partial.
struct LanguageSettingsView: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow

            ForEach(sortedProfiles) { profile in
                profileRow(profile: profile)
            }

            Text(
                "Disabled languages are never auto-applied to imported books. "
                    + "You can still pick them manually from the language menu."
            )
            .font(.system(size: 11))
            .foregroundStyle(.primary.opacity(Theme.Text.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Theme.Spacing.md)
        }
    }

    // MARK: - Header (tri-state)

    private var headerRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            TriStateCheckbox(state: headerState, onClick: toggleAll)
                .frame(width: 16)
            Text("Auto-detect on import")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(Theme.Text.secondary))
                .tracking(0.2)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.vertical, Theme.Spacing.sm)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    /// All enabled → checked. None enabled → unchecked. Otherwise mixed.
    private var headerState: NSControl.StateValue {
        if state.disabledProfileIDs.isEmpty { return .on }
        if state.disabledProfileIDs.count == state.allProfiles.count { return .off }
        return .mixed
    }

    /// macOS-standard tri-state click semantics: any non-fully-on state
    /// transitions to "all on"; "all on" transitions to "all off."
    private func toggleAll() {
        switch headerState {
        case .on: disableAll()
        case .off, .mixed: enableAll()
        default: enableAll()
        }
    }

    // MARK: - Rows

    private func profileRow(profile: LanguageProfile) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Toggle(
                "",
                isOn: Binding(
                    get: { !state.disabledProfileIDs.contains(profile.id) },
                    set: { state.setProfile(profile.id, enabled: $0) }
                )
            )
            .toggleStyle(.checkbox)
            .labelsHidden()
            .frame(width: 16)

            Text(profile.displayName)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary.opacity(Theme.Text.primary))
                .lineLimit(1)

            Spacer()

            Text(profile.id)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(.primary.opacity(Theme.Text.tertiary))
        }
        .padding(.vertical, Theme.Spacing.sm)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    // MARK: - Sorting + bulk

    private var sortedProfiles: [LanguageProfile] {
        state.allProfiles.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func enableAll() {
        for id in state.disabledProfileIDs {
            state.setProfile(id, enabled: true)
        }
    }

    private func disableAll() {
        for profile in state.allProfiles {
            state.setProfile(profile.id, enabled: false)
        }
    }
}
