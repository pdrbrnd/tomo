import AppKit
import SwiftUI

/// Window-level chrome adjustments that need direct NSWindow access.
///
/// The corner radius itself is *not* set here — AppKit's `NSThemeFrame` is
/// swizzled at app launch by `WindowChromeOverride` so the system draws the
/// frame, mask, and shadow at our preferred radius natively. This view only
/// handles things that survive on the window proper: background colour
/// (so the rounded mask is filled), shadow toggle, and traffic-light
/// repositioning (with re-apply on AppKit-driven state changes).
struct WindowCustomizer: NSViewRepresentable {
    var trafficLightInset: CGFloat = Theme.Chrome.trafficLightInset

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// State holder for the AppKit bridge. `@MainActor` because every read /
    /// write goes through SwiftUI's plumbing on the main actor; the
    /// `nonisolated deinit` lets us tear down observers without hopping
    /// back even if the last reference drops on a background thread
    /// (`NotificationCenter.removeObserver` is itself thread-safe).
    ///
    /// We deliberately stay on the callback API rather than the async-
    /// sequence form — Swift 6's `sending` rules choke on capturing a
    /// non-Sendable `NSView` across the implicit task hop, and the
    /// workarounds (`WeakBox`, separate per-name tasks) cost more
    /// clarity than they save.
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

        // Fill the rounded mask with our canvas colour. With NSThemeFrame
        // returning our radius, the system clips this to the right shape —
        // no contentView layer overrides or shadow invalidation needed.
        window.backgroundColor = NSColor(name: nil) { appearance in
            if isDarkAppearance(appearance) {
                return NSColor(srgbRed: 0.062, green: 0.062, blue: 0.066, alpha: 1.0)
            }
            return NSColor(srgbRed: 0.965, green: 0.961, blue: 0.953, alpha: 1.0)
        }
        window.hasShadow = true

        offsetTrafficLights(in: window, by: trafficLightInset, coordinator: coordinator)
        registerWindowObservers(window: window, view: view, coordinator: coordinator)
    }

    /// Nudges the standard window buttons (close, minimize, zoom) toward
    /// the content area by `inset` on both axes. Caches each button's
    /// original origin so subsequent applies are idempotent rather than
    /// compounding.
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
            // Title-bar coords aren't flipped — larger Y is higher on
            // screen, so visually moving DOWN means decreasing Y.
            button.setFrameOrigin(
                NSPoint(
                    x: original.x + inset,
                    y: original.y - inset
                ))
            // Pin the button so window resize / auto-layout can't drag it.
            button.autoresizingMask = []
        }
    }

    /// AppKit resets traffic-light positions on certain window state
    /// transitions (full-screen, mini, key changes). Observe those and
    /// re-apply our offsets so the buttons stay where we put them.
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
            let token = nc.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak view] _ in
                // Hop onto MainActor explicitly rather than asserting the
                // queue's isolation — robust against later refactors that
                // might change `queue:` or this struct's isolation.
                Task { @MainActor in
                    guard let view else { return }
                    apply(to: view, coordinator: coordinator)
                }
            }
            coordinator.observers.append(token)
        }
    }
}
