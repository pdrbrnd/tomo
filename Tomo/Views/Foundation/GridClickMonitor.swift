import AppKit
import SwiftUI

/// Lets the grid handle the second click even if opening the inspector
/// moved the first cover out from under the pointer.
struct GridClickMonitor: NSViewRepresentable {
    var onMouseEvent: (NSEvent) -> Bool

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak view] event in
            guard let view, let window = view.window, event.window === window else { return event }
            return view.onMouseEvent?(event) == true ? nil : event
        }
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) {
        view.onMouseEvent = onMouseEvent
    }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        if let monitor = view.monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    final class Anchor: NSView {
        var monitor: Any?
        var onMouseEvent: ((NSEvent) -> Bool)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
