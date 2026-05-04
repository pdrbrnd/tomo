import AppKit
import SwiftUI

/// Transparent NSView overlay that intercepts right-clicks only. Left-clicks
/// and drags pass through to the underlying SwiftUI view because `hitTest`
/// returns `nil` for any event that isn't a right-mouse event.
///
/// Use as `.overlay(RightClickCatcher { ... })` on any view that wants a
/// custom right-click handler — typically to open a popover instead of the
/// system context menu.
struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ClickView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ClickView)?.action = action
    }

    final class ClickView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only claim the hit when the current event is a right-mouse
            // event. For everything else (left-click, hover, drag start),
            // return nil so the SwiftUI content beneath us receives the
            // event unobstructed.
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return self
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            action?()
        }
    }
}
