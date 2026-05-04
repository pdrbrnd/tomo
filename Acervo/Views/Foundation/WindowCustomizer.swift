import SwiftUI
import AppKit

/// Bridges to the host NSWindow to set a custom corner radius on its content
/// view. macOS draws windows with a fixed system corner radius (~10pt); this
/// lets us go more rounded.
///
/// Important: the window stays `isOpaque = false` so the system's standard
/// window mask doesn't override our larger corner radius — but the
/// `backgroundColor` is set to an opaque canvas color (NOT clear). That keeps
/// the SwiftUI compositor opaque while allowing the custom shape. Setting
/// `backgroundColor` to clear collapses opacity throughout the contentView.
///
/// Also nudges the traffic lights inward by `trafficLightInset` so they line
/// up with the inner panes (which sit at the same inset from the window
/// edge). The original positions are cached on the Coordinator so re-applies
/// are idempotent. Window state-change notifications re-apply automatically
/// because AppKit resets traffic lights on full-screen, resize, etc.
struct WindowCustomizer: NSViewRepresentable {
    let cornerRadius: CGFloat
    var trafficLightInset: CGFloat = 10

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var originalOrigins: [NSWindow.ButtonType: NSPoint] = [:]
        var hasRegisteredObservers = false
        // Observers live for the window's lifetime — same as the
        // Coordinator. NotificationCenter holds them; the closures capture
        // `view` weakly so they don't keep dead references alive.
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            apply(to: view, coordinator: coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView else { return }
            apply(to: nsView, coordinator: coordinator)
        }
    }

    private func apply(to view: NSView, coordinator: Coordinator) {
        guard let window = view.window else { return }
        guard let contentView = window.contentView else { return }

        applyCornerRadius(to: contentView)

        // The content view's layer alone doesn't cover the window's actual
        // on-screen mask: the system clips the window at its default ~10pt
        // radius, which shows as a faint trace just outside our 28pt curve.
        // Walk up the hierarchy and apply the corner radius to every
        // ancestor so the entire visual stack — including the internal
        // NSThemeFrame and any decoration views above it — clips to our
        // shape.
        var ancestor: NSView? = contentView.superview
        while let current = ancestor {
            applyCornerRadius(to: current)
            // Drop any system-drawn 1pt border at the old radius.
            current.layer?.borderWidth = 0
            ancestor = current.superview
        }

        window.isOpaque = false
        window.backgroundColor = NSColor(name: nil) { appearance in
            if isDarkAppearance(appearance) {
                return NSColor(srgbRed: 0.062, green: 0.062, blue: 0.066, alpha: 1.0)
            }
            return NSColor(srgbRed: 0.965, green: 0.961, blue: 0.953, alpha: 1.0)
        }
        window.hasShadow = true
        // Recompute the system shadow against the new (rounder) shape so
        // it doesn't trace the original ~10pt rectangle.
        window.invalidateShadow()

        offsetTrafficLights(in: window, by: trafficLightInset, coordinator: coordinator)
        registerWindowObservers(window: window, view: view, coordinator: coordinator)
    }

    private func applyCornerRadius(to view: NSView) {
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }

    /// Nudges the standard window buttons (close, minimize, zoom) toward the
    /// content area by `inset` on both axes. Records each button's original
    /// origin in the Coordinator on first call so subsequent applies are
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
            // macOS title-bar coords aren't flipped: larger Y is higher on
            // screen. Visually moving DOWN means decreasing Y.
            button.setFrameOrigin(NSPoint(
                x: original.x + inset,
                y: original.y - inset
            ))
            // Pin the button so window resize/auto-layout can't move it.
            button.autoresizingMask = []
        }
    }

    /// AppKit resets traffic-light positions on certain window state
    /// transitions (full-screen, mini, key changes). Observe those and
    /// re-apply our offsets so the buttons stay where we put them.
    private func registerWindowObservers(window: NSWindow, view: NSView, coordinator: Coordinator) {
        guard !coordinator.hasRegisteredObservers else { return }
        coordinator.hasRegisteredObservers = true

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
            nc.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak view] _ in
                // queue: .main runs the closure on the main thread, which
                // is the MainActor — but Swift Concurrency doesn't infer
                // that for NotificationCenter callbacks, so assert it.
                MainActor.assumeIsolated {
                    guard let view else { return }
                    apply(to: view, coordinator: coordinator)
                }
            }
        }
    }
}
