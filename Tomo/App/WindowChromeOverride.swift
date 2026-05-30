import AppKit
import ObjectiveC.runtime
import os

/// Forces the AppKit `NSThemeFrame` (the private view that owns the window's
/// mask, shadow, and corner geometry) to return our preferred corner radius
/// from the four selectors AppKit consults.
///
/// **Why this exists.** macOS doesn't expose a public API to set a custom
/// window corner radius. macOS 26 (Tahoe) gives windows ~16pt with no
/// toolbar, ~26pt with one — but no knob. Setting `contentView.layer
/// .cornerRadius` only clips *our* content; the underlying `NSThemeFrame`
/// keeps drawing the mask + shadow at the system value, which produces a
/// faint dark "double-rounding" trace at the corners.
///
/// **What it does.** Replaces these four `NSThemeFrame` instance methods at
/// app launch:
///   - `_cornerRadius` (CGFloat)
///   - `_getCachedWindowCornerRadius` (CGFloat)
///   - `_topCornerSize` (CGSize)
///   - `_bottomCornerSize` (CGSize)
///
/// Once these return our value, AppKit draws frame, mask, and shadow at
/// that radius natively — no compositing tricks, no shadow invalidation,
/// no walk-up of layer hierarchies.
///
/// **Risks and constraints.**
///   - Private API. Verified on macOS 26.4 (2026-05-04). Re-verify after
///     deployment-target bumps.
///   - App Store would reject this. Tomo ships via Homebrew cask
///     (sandbox off) per `CLAUDE.md`, so it's a non-issue.
///   - Replaces `NSThemeFrame`'s implementation globally for the process,
///     i.e. *every* window in the app gets the same corner radius. The
///     library's traffic lights are then offset to sit concentrically with
///     that radius (see `installTrafficLightOffset`); other windows use the
///     notification-based offset in `WindowCustomizer`.
///
/// **Reference.** The four-selector pattern is documented at
/// https://github.com/m4rkw/macos-corner-fix and discussed in Mark
/// Wadham's writeup at https://markwadh.am/blog/macos-tahoe-rounded-corner-fix.html.
@MainActor
enum WindowChromeOverride {
    private static let logger = Logger(subsystem: "com.pdrbrnd.tomo", category: "window-chrome")
    private static var installed = false

    /// True once the library's traffic-light offset is applied inside
    /// `NSThemeFrame`'s layout pass (the jump-free path). `WindowCustomizer`
    /// reads this so it doesn't *also* offset the library and double the inset.
    private(set) static var repositionsTrafficLights = false

    /// Installs the override. Idempotent — only swizzles on the first call.
    /// Must be called *before* the first window is shown (TomoApp.init).
    static func install(cornerRadius: CGFloat, trafficLightInset: CGFloat) {
        guard !installed else { return }
        installed = true

        guard let themeFrame = NSClassFromString("NSThemeFrame") else {
            // NSThemeFrame is private — if Apple ever renames it, fail
            // soft and let the system render the default radius.
            logger.warning("NSThemeFrame not found — falling back to system corner radius")
            return
        }

        let cgFloatReturn: @convention(block) (AnyObject) -> CGFloat = { _ in cornerRadius }
        let cgSizeReturn: @convention(block) (AnyObject) -> CGSize = { _ in
            CGSize(width: cornerRadius, height: cornerRadius)
        }

        let succeeded = [
            replace(themeFrame, selector: "_cornerRadius", with: cgFloatReturn),
            replace(themeFrame, selector: "_getCachedWindowCornerRadius", with: cgFloatReturn),
            replace(themeFrame, selector: "_topCornerSize", with: cgSizeReturn),
            replace(themeFrame, selector: "_bottomCornerSize", with: cgSizeReturn),
        ]

        let missingCount = succeeded.filter { !$0 }.count
        if missingCount == succeeded.count {
            logger.warning(
                "None of the NSThemeFrame corner-radius selectors were found — system radius will apply")
        } else if missingCount > 0 {
            logger.warning(
                "\(missingCount) of \(succeeded.count) corner-radius selectors missing — partial override; corners may render inconsistently"
            )
        }

        repositionsTrafficLights = installTrafficLightOffset(themeFrame, inset: trafficLightInset)
    }

    /// Offsets the standard window buttons by `inset` *inside* `NSThemeFrame`'s
    /// `-layout`, after AppKit places them at their defaults. Running every
    /// layout pass (including each live-resize frame) means the buttons never
    /// lag — no resize jump. Used for the library (resizable); short-title-bar
    /// windows (Settings/reader) use the notification offset instead, since the
    /// swizzle left their click region behind the visual position.
    ///
    /// Refuses to swizzle unless `NSThemeFrame` implements `-layout` *itself*:
    /// otherwise `class_getInstanceMethod` resolves to `NSView.layout` and
    /// `method_setImplementation` would clobber layout for every view in the
    /// process. On refusal `WindowCustomizer` falls back to the notification
    /// offset for the library too.
    private static func installTrafficLightOffset(_ cls: AnyClass, inset: CGFloat) -> Bool {
        let sel = NSSelectorFromString("layout")
        guard classDirectlyImplements(cls, sel),
            let method = class_getInstanceMethod(cls, sel)
        else {
            logger.warning(
                "NSThemeFrame doesn't implement -layout directly — keeping notification-based traffic-light offset"
            )
            return false
        }

        typealias LayoutFunc = @convention(c) (AnyObject, Selector) -> Void
        let originalIMP = method_getImplementation(method)
        let block: @convention(block) (AnyObject) -> Void = { themeFrame in
            // Let AppKit lay the frame (and buttons at their defaults) out first.
            unsafeBitCast(originalIMP, to: LayoutFunc.self)(themeFrame, sel)
            // `-layout` is always called on the main thread.
            MainActor.assumeIsolated {
                guard let view = themeFrame as? NSView, let window = view.window,
                    // The resizable inset windows (library + reader). The
                    // non-resizable Settings window is excluded — the swizzle
                    // left its click region behind the visual position there,
                    // so it uses the notification offset instead.
                    window.identifier == .libraryWindow || window.identifier == .readerWindow
                else { return }
                for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    guard let button = window.standardWindowButton(type) else { continue }
                    // Title-bar coords aren't flipped — moving DOWN means a
                    // smaller Y. Offset from the freshly-laid-out default, so
                    // it never compounds across passes.
                    let origin = button.frame.origin
                    button.setFrameOrigin(NSPoint(x: origin.x + inset, y: origin.y - inset))
                    // Rebuild the button's hover tracking at its new position so
                    // the glyph reveal triggers on the button, not its old spot.
                    button.updateTrackingAreas()
                }
                // Per-button tracking is fixed above; the cluster's group hover
                // rect lives on an ancestor and needs an explicit rebuild —
                // otherwise the all-glyphs hover stays at the default spot until
                // a resize relayout rebuilds it.
                window.rebuildTrafficLightClusterTracking()
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        return true
    }

    /// Whether `cls` implements `sel` in its own method list (not inherited).
    private static func classDirectlyImplements(_ cls: AnyClass, _ sel: Selector) -> Bool {
        var count: UInt32 = 0
        guard let list = class_copyMethodList(cls, &count) else { return false }
        defer { free(list) }
        for index in 0..<Int(count) where method_getName(list[index]) == sel {
            return true
        }
        return false
    }

    @discardableResult
    private static func replace(
        _ cls: AnyClass,
        selector name: String,
        with block: Any
    ) -> Bool {
        let sel = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(cls, sel) else {
            logger.warning("Selector \(name) not found on \(NSStringFromClass(cls), privacy: .public)")
            return false
        }
        let imp = imp_implementationWithBlock(block)
        method_setImplementation(method, imp)
        return true
    }
}
