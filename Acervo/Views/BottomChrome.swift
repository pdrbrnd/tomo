import SwiftUI

/// Bottom-edge floating row: sidebar toggle (leading) + search pill (centered)
/// + inspector toggle (trailing). Floats over the entire window — including
/// over the sidebar and inspector when they're open — so the toggle buttons
/// stay in the same screen position. Tap the same spot to open *or* close
/// each pane; the icon's filled state reflects whether the pane is open.
struct BottomChrome: View {
    @Binding var searchText: String
    var searchFocused: FocusState<Bool>.Binding
    let searchPlaceholder: String
    let sidebarOpen: Bool
    let inspectorOpen: Bool
    let onToggleSidebar: () -> Void
    let onToggleInspector: () -> Void

    /// 14pt padding from window edges + 16pt button radius (32pt diameter)
    /// puts each toggle's center at (30, 30) from the corner — concentric
    /// with the panel curve (also at (30, 30): paneInset 8 + R_panel 22)
    /// and the window curve (R_window 30). Gap from button edge to panel
    /// curve = R_panel − r_btn = 22 − 16 = 6pt of breathing room.
    static var bottomPadding: CGFloat { 14 }
    static var horizontalPadding: CGFloat { 14 }
    static var buttonDiameter: CGFloat { 32 }

    var body: some View {
        ZStack {
            HStack {
                Spacer()
                SearchPill(text: $searchText, placeholder: searchPlaceholder)
                    .focused(searchFocused)
                Spacer()
            }

            HStack {
                sidebarButton
                    .padding(.leading, Self.horizontalPadding)
                Spacer()
                inspectorButton
                    .padding(.trailing, Self.horizontalPadding)
            }
        }
        // Empty regions of the chrome blur the search on click. As a
        // `.background` (not a ZStack child), this sizes to the chrome's
        // natural content frame — it doesn't expand the chrome to fill the
        // window, so it doesn't eat clicks outside the bottom strip.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { searchFocused.wrappedValue = false }
        )
        .padding(.bottom, Self.bottomPadding)
    }

    private var sidebarButton: some View {
        Button(action: onToggleSidebar) {
            chromeButtonLabel(symbol: "sidebar.left", active: sidebarOpen)
        }
        .buttonStyle(.plain)
        .help(sidebarOpen ? "Hide sidebar (⌃⌘S)" : "Show sidebar (⌃⌘S)")
    }

    private var inspectorButton: some View {
        Button(action: onToggleInspector) {
            chromeButtonLabel(symbol: "sidebar.right", active: inspectorOpen)
        }
        .buttonStyle(.plain)
        .help(inspectorOpen ? "Hide details (⌘I)" : "Show details (⌘I)")
    }

    private func chromeButtonLabel(symbol: String, active: Bool) -> some View {
        ZStack {
            Circle().fill(Theme.surface)
            Circle().stroke(Theme.hairline, lineWidth: 0.5)
            // SF Symbols' sidebar.* don't ship a fill variant, so the
            // active state shifts weight + opacity instead.
            Icon(symbol: symbol, weight: active ? .semibold : .regular, size: 14)
                .foregroundStyle(.primary.opacity(active ? 0.92 : 0.62))
        }
        .frame(width: Self.buttonDiameter, height: Self.buttonDiameter)
        .softShadow(elevated: active)
    }
}
