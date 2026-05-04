import SwiftUI

/// The marquee rectangle drawn while drag-selecting in the library grid.
/// Uses the system accent at low alpha for the fill and a thin solid border
/// for the edge — matches the look of Finder's selection rectangle without
/// trying to copy it pixel for pixel.
struct SelectionRectangle: View {
    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.12)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .stroke(Color.accentColor.opacity(0.55), lineWidth: 0.75)
        }
    }
}
