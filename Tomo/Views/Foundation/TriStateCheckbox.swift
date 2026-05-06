import AppKit
import SwiftUI

/// Standard macOS tri-state checkbox (`NSButton.allowsMixedState`). SwiftUI's
/// `Toggle(.checkbox)` is binary; for "select all / select none / mixed" we
/// drop down to AppKit. The button calls `onClick` on every press — the
/// parent decides what state transition that means (typical macOS behaviour:
/// off→on, on→off, mixed→on).
struct TriStateCheckbox: NSViewRepresentable {
    /// Visual state. Set externally; the control doesn't track it itself.
    let state: NSControl.StateValue
    let onClick: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onClick: onClick)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        button.allowsMixedState = true
        button.target = context.coordinator
        button.action = #selector(Coordinator.click(_:))
        button.setButtonType(.switch)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.state = state
        context.coordinator.onClick = onClick
    }

    @MainActor
    final class Coordinator: NSObject {
        var onClick: () -> Void

        init(onClick: @escaping () -> Void) {
            self.onClick = onClick
        }

        @objc func click(_ sender: NSButton) {
            // AppKit auto-cycles tri-state on click (off→on→mixed). We
            // override to call the parent's handler with the *previous*
            // state semantics; parent decides what to do next.
            onClick()
        }
    }
}
