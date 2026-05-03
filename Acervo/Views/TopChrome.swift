import SwiftUI
import PhosphorSwift

/// The persistent top row of the main pane: traffic lights are owned by the
/// system; search pill centers in the remaining space; the filter button
/// floats at the trailing edge. Filter content is passed in by the parent so
/// this view doesn't know about language tags.
struct TopChrome<FilterContent: View>: View {
    @Binding var searchText: String
    var searchFocused: FocusState<Bool>.Binding
    let isFilterActive: Bool
    @ViewBuilder var filterContent: () -> FilterContent

    @State private var showFilterPopover = false

    /// Top edge offset from the window — kept in sync with the inspector
    /// close button so they align horizontally when the inspector is open.
    static var topPadding: CGFloat { 16 }
    static var trailingPadding: CGFloat { 16 }
    /// Leading offset so the centered search pill clears the traffic lights.
    static var leadingTrafficLightClearance: CGFloat { 80 }

    var body: some View {
        ZStack {
            HStack {
                Spacer()
                SearchPill(text: $searchText)
                    .focused(searchFocused)
                Spacer()
            }
            .padding(.leading, Self.leadingTrafficLightClearance)

            HStack {
                Spacer()
                filterButton
                    .padding(.trailing, Self.trailingPadding)
            }
        }
        .padding(.top, Self.topPadding)
    }

    private var filterButton: some View {
        Button {
            showFilterPopover.toggle()
        } label: {
            ZStack {
                Circle().fill(Theme.surface)
                Circle().stroke(Theme.hairline, lineWidth: 0.5)
                Icon(symbol: .funnelSimple, weight: .regular, size: 14)
                    .foregroundStyle(.primary.opacity(isFilterActive ? 0.92 : 0.62))
            }
            .frame(width: 32, height: 32)
            .softShadow(elevated: showFilterPopover)
            .overlay(alignment: .topTrailing) {
                if isFilterActive {
                    Circle()
                        .fill(.primary)
                        .frame(width: 6, height: 6)
                        .offset(x: 1, y: -1)
                }
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showFilterPopover, arrowEdge: .top) {
            filterContent()
        }
        .help("Filter by language")
    }
}
