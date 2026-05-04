import SwiftUI
import PhosphorSwift

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

    /// 12pt padding from the window edges so each toggle button's center
    /// (16pt + 12pt = 28pt from corner) coincides with the window's and
    /// panel's corner-curve centers — three concentric circles.
    static var bottomPadding: CGFloat { 12 }
    static var horizontalPadding: CGFloat { 12 }

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
            chromeButtonLabel(symbol: .sidebar, active: sidebarOpen)
        }
        .buttonStyle(.plain)
        .help(sidebarOpen ? "Hide sidebar (⌃⌘S)" : "Show sidebar (⌃⌘S)")
    }

    private var inspectorButton: some View {
        Button(action: onToggleInspector) {
            chromeButtonLabel(symbol: .squareHalf, active: inspectorOpen)
        }
        .buttonStyle(.plain)
        .help(inspectorOpen ? "Hide details (⌘I)" : "Show details (⌘I)")
    }

    private func chromeButtonLabel(symbol: Ph, active: Bool) -> some View {
        ZStack {
            Circle().fill(Theme.surface)
            Circle().stroke(Theme.hairline, lineWidth: 0.5)
            Icon(symbol: symbol, weight: active ? .fill : .regular, size: 14)
                .foregroundStyle(.primary.opacity(active ? 0.92 : 0.62))
        }
        .frame(width: 32, height: 32)
        .softShadow(elevated: active)
    }
}
