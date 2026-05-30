import AppKit
import SwiftUI

extension NSWindow {
    /// Rebuilds the traffic-light cluster's *group* hover tracking rect at the
    /// buttons' current (offset) positions.
    ///
    /// Moving the standard buttons by hand and calling `updateTrackingAreas()`
    /// on each button fixes their individual rects, but the rect that reveals
    /// all three glyphs when you hover anywhere over the cluster is owned by an
    /// ancestor view in the title bar, not the buttons. AppKit only rebuilds it
    /// on a relayout — which is why a window resize "fixes" the hover, and why
    /// the non-resizable Settings window never recovers on its own.
    ///
    /// Walking `updateTrackingAreas()` up from the button's superview to
    /// `NSThemeFrame` forces that rebuild now, at the offset positions.
    @MainActor
    func rebuildTrafficLightClusterTracking() {
        guard let close = standardWindowButton(.closeButton) else { return }
        var view: NSView? = close.superview
        while let current = view {
            current.updateTrackingAreas()
            if NSStringFromClass(type(of: current)) == "NSThemeFrame" { break }
            view = current.superview
        }
    }
}

extension NSUserInterfaceItemIdentifier {
    /// Tags the resizable windows whose traffic lights the `NSThemeFrame`
    /// layout swizzle offsets — jump-free during live resize. (The
    /// non-resizable Settings window uses the notification offset instead; the
    /// swizzle left its click region behind on that one.)
    static let libraryWindow = NSUserInterfaceItemIdentifier("tomo.libraryWindow")
    static let readerWindow = NSUserInterfaceItemIdentifier("tomo.readerWindow")
}

/// Window-level chrome that needs direct `NSWindow` access: fills the rounded
/// mask with our canvas colour, turns on the shadow, and insets the traffic
/// lights to sit concentrically with our rounded panes.
///
/// macOS has no API to place the standard buttons at an arbitrary point, so we
/// reposition them with `setFrameOrigin`. Two mechanisms, by window:
///   - **Library** (resizable): `WindowChromeOverride`'s layout swizzle does it
///     every layout pass, so the buttons never lag during a live resize.
///   - **Settings / reader**: the notification-based offset here, which keeps
///     the click region aligned with the buttons (the swizzle desynced clicks
///     on these short-title-bar windows).
///
/// Repositioning by hand leaves AppKit's *group* hover rect (the one that
/// reveals all three glyphs) at the default spot until a relayout rebuilds it.
/// Both paths call `rebuildTrafficLightClusterTracking()` after offsetting to
/// force that rebuild now, so the hover aligns on first show without a resize.
struct WindowCustomizer: NSViewRepresentable {
    var trafficLightInset: CGFloat = Theme.Chrome.trafficLightInset
    /// Set only on the library window — the layout swizzle offsets its buttons
    /// for this identifier.
    var windowID: NSUserInterfaceItemIdentifier?
    /// Whether this window's traffic lights should be inset. The library uses
    /// the swizzle (above); other windows that want the inset get the
    /// notification-based offset here.
    var wantsInsetTrafficLights = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// State holder for the AppKit bridge. `@MainActor` because every read /
    /// write goes through SwiftUI's plumbing on the main actor; the
    /// `nonisolated deinit` lets us tear down observers without hopping back
    /// even if the last reference drops on a background thread
    /// (`NotificationCenter.removeObserver` is itself thread-safe).
    @MainActor final class Coordinator {
        var originalOrigins: [NSWindow.ButtonType: NSPoint] = [:]
        nonisolated(unsafe) var observers: [NSObjectProtocol] = []

        nonisolated deinit {
            for token in observers {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        Task { @MainActor [weak view] in
            guard let view else { return }
            apply(to: view, coordinator: coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        Task { @MainActor [weak nsView] in
            guard let nsView else { return }
            apply(to: nsView, coordinator: coordinator)
        }
    }

    private func apply(to view: NSView, coordinator: Coordinator) {
        guard let window = view.window else { return }

        // Tag the library window so the layout swizzle offsets its buttons.
        // Nudge a relayout so the offset applies now rather than on first
        // resize (the identifier is set after the initial layout pass).
        if let windowID {
            window.identifier = windowID
            window.contentView?.superview?.needsLayout = true
        }

        // Fill the rounded mask with our canvas colour. With NSThemeFrame
        // returning our radius, the system clips this to the right shape.
        window.backgroundColor = NSColor(name: nil) { appearance in
            if isDarkAppearance(appearance) {
                return NSColor(srgbRed: 0.062, green: 0.062, blue: 0.066, alpha: 1.0)
            }
            return NSColor(srgbRed: 0.965, green: 0.961, blue: 0.953, alpha: 1.0)
        }
        window.hasShadow = true

        // The library's lights are offset by the layout swizzle (gated on its
        // identifier); doing it here too would double the inset. Every other
        // window that wants the inset uses the notification-based offset, which
        // keeps the click region aligned. Also the library's fallback if the
        // swizzle couldn't attach.
        if wantsInsetTrafficLights && !swizzleHandlesThisWindow {
            offsetTrafficLights(in: window, by: trafficLightInset, coordinator: coordinator)
            registerWindowObservers(window: window, view: view, coordinator: coordinator)
        }
    }

    private var swizzleHandlesThisWindow: Bool {
        WindowChromeOverride.repositionsTrafficLights
            && (windowID == .libraryWindow || windowID == .readerWindow)
    }

    /// Nudges the standard window buttons toward the content area by `inset` on
    /// both axes. Caches each button's original origin so re-applies are
    /// idempotent rather than compounding.
    private func offsetTrafficLights(in window: NSWindow, by inset: CGFloat, coordinator: Coordinator) {
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

        for type in types {
            guard let button = window.standardWindowButton(type) else { continue }
            let original: NSPoint
            if let stored = coordinator.originalOrigins[type] {
                original = stored
            } else {
                original = button.frame.origin
                coordinator.originalOrigins[type] = original
            }
            // Title-bar coords aren't flipped — larger Y is higher on screen,
            // so visually moving DOWN means decreasing Y.
            button.setFrameOrigin(NSPoint(x: original.x + inset, y: original.y - inset))
            // Pin the button so window resize / auto-layout can't drag it.
            button.autoresizingMask = []
            // Rebuild the hover tracking at the new position so the glyph
            // reveal triggers on the button, not its old spot.
            button.updateTrackingAreas()
        }
        // Per-button tracking is fixed above; the cluster's group hover rect
        // lives on an ancestor and needs an explicit rebuild.
        window.rebuildTrafficLightClusterTracking()
    }

    /// AppKit resets traffic-light positions on certain window state
    /// transitions. Observe those and re-apply our offsets.
    private func registerWindowObservers(window: NSWindow, view: NSView, coordinator: Coordinator) {
        guard coordinator.observers.isEmpty else { return }

        let nc = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeBackingPropertiesNotification,
        ]
        for name in names {
            let token = nc.addObserver(forName: name, object: window, queue: .main) { [weak view] _ in
                // Hop onto MainActor explicitly rather than asserting the
                // queue's isolation — robust against later refactors.
                Task { @MainActor in
                    guard let view else { return }
                    apply(to: view, coordinator: coordinator)
                }
            }
            coordinator.observers.append(token)
        }
    }
}
