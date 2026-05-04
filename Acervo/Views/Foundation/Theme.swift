import SwiftUI
import AppKit

// Visual tokens. Opinionated values — not the system defaults.
// Any tweak we make should pass through here so we don't drift.
enum Theme {
    // Canvas: warm off-white in light, slightly-warm off-black in dark.
    // The point of these is to *not* be the system grey, which reads as default.
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        if isDarkAppearance(appearance) {
            return NSColor(srgbRed: 0.062, green: 0.062, blue: 0.066, alpha: 1.0)
        }
        return NSColor(srgbRed: 0.965, green: 0.961, blue: 0.953, alpha: 1.0)
    })

    // Surface: a card / pill background that sits on the canvas. Visibly
    // brighter than the canvas so cards/pills read as elevated.
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        if isDarkAppearance(appearance) {
            return NSColor(srgbRed: 0.155, green: 0.155, blue: 0.160, alpha: 1.0)
        }
        return NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
    })

    // Hairline: the border that catches light on cards/pills. Theme-adaptive.
    static let hairline = Color(nsColor: NSColor(name: nil) { appearance in
        if isDarkAppearance(appearance) {
            return NSColor(white: 1.0, alpha: 0.06)
        }
        return NSColor(white: 0.0, alpha: 0.06)
    })

    // Panel: same as canvas in light (no contrast — relies on hairline + shadow
    // to define the panel), a touch brighter than canvas in dark so the
    // sidebar reads as a separate plane. Used by the inspector.
    static let panel = Color(nsColor: NSColor(name: nil) { appearance in
        if isDarkAppearance(appearance) {
            return NSColor(srgbRed: 0.090, green: 0.090, blue: 0.094, alpha: 1.0)
        }
        return NSColor(srgbRed: 0.965, green: 0.961, blue: 0.953, alpha: 1.0)
    })

    // Concentric corner radii. The rule everywhere: r_inner = r_outer − gap.
    // Tuned so the bottom-chrome 32pt buttons' centers coincide with both
    // the panel and the window corner-curve centers — three concentric
    // circles at the corners with 6pt of breathing room between the
    // button edge and the panel curve.
    //
    // Window (30) − pane inset (8)        = panel (22)
    // Panel  (22) − menuInset (6)         = sidebarRow (16)
    // Menu   (18) − menuInset (6)         = menuItem (12)
    // Card    (8) − cover-content gap (4) = cover (4)
    //
    // Bottom-chrome button: 32pt diameter (r=16), 14pt padding from window
    // edges → center at (30, 30) from corner = panel curve center = window
    // curve center. Button-to-panel gap = 22 − 16 = 6pt.
    enum Radius {
        static let cover: CGFloat = 4
        static let card: CGFloat = 8
        static let panel: CGFloat = 22

        /// Row backgrounds inside a panel (sidebar rows). Concentric with
        /// the panel given the standard menuInset (6) padding.
        static let sidebarRow: CGFloat = 16

        static let menu: CGFloat = 18
        static let menuItem: CGFloat = 12
        static let window: CGFloat = 30
    }

    // Spacing scale — every gap is one of these.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let menuInset: CGFloat = 6
    }
}

func isDarkAppearance(_ appearance: NSAppearance) -> Bool {
    let darkNames: Set<NSAppearance.Name> = [
        .darkAqua,
        .vibrantDark,
        .accessibilityHighContrastDarkAqua,
        .accessibilityHighContrastVibrantDark
    ]
    if darkNames.contains(appearance.name) { return true }
    return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
}

// Two-layer shadow vocabulary — a tight close shadow that grounds the object,
// plus a wider diffuse shadow that gives weight. Used by cards / pills /
// floating panels uniformly.
extension View {
    func softShadow(elevated: Bool) -> some View {
        self
            .shadow(
                color: .black.opacity(elevated ? 0.05 : 0.03),
                radius: 1,
                x: 0,
                y: 1
            )
            .shadow(
                color: .black.opacity(elevated ? 0.16 : 0.09),
                radius: elevated ? 22 : 12,
                x: 0,
                y: elevated ? 12 : 6
            )
    }

    /// Softer two-layer shadow for the big floating panes (sidebar,
    /// inspector). The elevated `softShadow` reads as too heavy on a
    /// full-height panel — its weight is calibrated for ~card-sized
    /// surfaces. This trims opacity and radius so the seam between pane
    /// and canvas reads as subtle elevation, not a dropped-in card.
    func paneShadow() -> some View {
        self
            .shadow(color: .black.opacity(0.04), radius: 1, x: 0, y: 1)
            .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 8)
    }
}
