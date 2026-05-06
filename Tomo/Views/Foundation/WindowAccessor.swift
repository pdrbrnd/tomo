import AppKit
import SwiftUI

/// Hook that surfaces the SwiftUI view's host `NSWindow` so callers can apply
/// window-level configuration (style mask, identifier, title visibility,
/// etc.) that has no SwiftUI equivalent.
///
/// Use as a `.background(...)` modifier on a view inside the window. The
/// closure runs once the view is mounted in a window — typically next runloop
/// tick after the view appears.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                configure(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
