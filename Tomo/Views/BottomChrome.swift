import SwiftUI

/// Bottom-edge pane toggles. Floats over the entire window — including
/// over the sidebar and inspector when they're open — so the toggle buttons
/// stay in the same screen position. Tap the same spot to open *or* close
/// each pane; the icon's filled state reflects whether the pane is open.
struct BottomChrome: View {
    let sidebarOpen: Bool
    let inspectorOpen: Bool
    let onToggleSidebar: () -> Void
    let onToggleInspector: () -> Void

    /// Concentric-circles math lives in `Theme.Chrome`. Toggle center =
    /// `toggleEdgeInset + toggleDiameter/2` matches both the panel curve
    /// center (`paneInset + Radius.panel`) and the window curve center
    /// (`Radius.window`).
    static var bottomPadding: CGFloat { Theme.Chrome.toggleEdgeInset }
    static var horizontalPadding: CGFloat { Theme.Chrome.toggleEdgeInset }
    static var buttonDiameter: CGFloat { Theme.Chrome.toggleDiameter }

    var body: some View {
        HStack {
            sidebarButton
                .padding(.leading, Self.horizontalPadding)
            Spacer()
            inspectorButton
                .padding(.trailing, Self.horizontalPadding)
        }
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
            Circle().fill(Theme.overlaySurface)
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
