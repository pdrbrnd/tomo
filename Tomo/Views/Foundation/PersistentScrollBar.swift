import AppKit
import SwiftUI

/// Attach inside a ScrollView's content to keep its native scroller visible
/// even when macOS is set to auto-hide scroll bars.
struct PersistentScrollBar: NSViewRepresentable {
    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        NotificationCenter.default.addObserver(
            view,
            selector: #selector(Anchor.preferredStyleDidChange),
            name: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil
        )
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) {
        view.applyScrollerStyle()
    }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        NotificationCenter.default.removeObserver(view)
        view.restoreScrollerStyle()
    }

    final class Anchor: NSView {
        private weak var scrollView: NSScrollView?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyScrollerStyle()
        }

        func applyScrollerStyle() {
            guard window != nil, let enclosingScrollView else { return }
            scrollView = enclosingScrollView
            enclosingScrollView.scrollerStyle = .legacy
        }

        func restoreScrollerStyle() {
            scrollView?.scrollerStyle = NSScroller.preferredScrollerStyle
            scrollView = nil
        }

        @objc func preferredStyleDidChange() {
            // Apply after AppKit updates scroll views to the system style.
            Task { @MainActor [weak self] in
                self?.scrollView?.scrollerStyle = .legacy
            }
        }
    }
}
