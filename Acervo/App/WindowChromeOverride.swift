import AppKit
import ObjectiveC.runtime

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
///   - App Store would reject this. Acervo ships via Homebrew cask
///     (sandbox off) per `CLAUDE.md`, so it's a non-issue.
///   - Replaces `NSThemeFrame`'s implementation globally for the process,
///     i.e. *every* window in the app gets the same corner radius. We
///     only have one window class, so this is fine.
///
/// **Reference.** The four-selector pattern is documented at
/// https://github.com/m4rkw/macos-corner-fix and discussed in Mark
/// Wadham's writeup at https://markwadh.am/blog/macos-tahoe-rounded-corner-fix.html.
@MainActor
enum WindowChromeOverride {
    private static var installed = false

    /// Installs the override. Idempotent — only swizzles on the first call.
    /// Must be called *before* the first window is shown (AcervoApp.init).
    static func install(cornerRadius: CGFloat) {
        guard !installed else { return }
        installed = true

        guard let themeFrame = NSClassFromString("NSThemeFrame") else {
            // NSThemeFrame is private — if Apple ever renames it, fail
            // soft and let the system render the default radius.
            return
        }

        let radius = cornerRadius

        let cgFloatReturn: @convention(block) (AnyObject) -> CGFloat = { _ in radius }
        let cgSizeReturn: @convention(block) (AnyObject) -> CGSize = { _ in
            CGSize(width: radius, height: radius)
        }

        replace(themeFrame, selector: "_cornerRadius", with: cgFloatReturn)
        replace(themeFrame, selector: "_getCachedWindowCornerRadius", with: cgFloatReturn)
        replace(themeFrame, selector: "_topCornerSize", with: cgSizeReturn)
        replace(themeFrame, selector: "_bottomCornerSize", with: cgSizeReturn)
    }

    private static func replace(
        _ cls: AnyClass,
        selector name: String,
        with block: Any
    ) {
        let sel = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        let imp = imp_implementationWithBlock(block)
        method_setImplementation(method, imp)
    }
}
