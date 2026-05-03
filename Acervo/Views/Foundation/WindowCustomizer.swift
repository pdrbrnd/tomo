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
struct WindowCustomizer: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            apply(to: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView else { return }
            apply(to: nsView)
        }
    }

    private func apply(to view: NSView) {
        guard let window = view.window else { return }
        guard let contentView = window.contentView else { return }

        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = cornerRadius
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.masksToBounds = true

        window.isOpaque = false
        window.backgroundColor = NSColor(name: nil) { appearance in
            if isDarkAppearance(appearance) {
                return NSColor(srgbRed: 0.062, green: 0.062, blue: 0.066, alpha: 1.0)
            }
            return NSColor(srgbRed: 0.965, green: 0.961, blue: 0.953, alpha: 1.0)
        }
        window.hasShadow = true
    }
}
