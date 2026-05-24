import Darwin
import JavaScriptCore
import os

/// Installs a hard CPU-time cap on a `JSContext`'s execution.
///
/// The underlying SPI (`JSContextGroupSetExecutionTimeLimit`) is exported by
/// JavaScriptCore's dylib but absent from the public SDK header — declared
/// in WebKit's `JSContextRefPrivate.h`. Rather than add a custom modulemap
/// (which requires Xcode project surgery), we resolve the symbol at runtime
/// via `dlsym`. If a future macOS removes the export, plugins lose this
/// defense and a `while(true){}` plugin can hang its own invocation
/// (though not freeze the UI — calls are async).
enum JSCExecutionLimit {

    /// `bool (*)(JSContextRef ctx, void* context)` — returning `true` tells
    /// the engine to terminate the running script. We always say yes.
    private typealias ShouldTerminateCallback = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Bool

    /// `void (*)(JSContextGroupRef, double, JSShouldTerminateCallback, void*)`
    private typealias SetLimitFn =
        @convention(c) (
            OpaquePointer?, Double, ShouldTerminateCallback?, UnsafeMutableRawPointer?
        ) -> Void

    nonisolated private static let setLimit: SetLimitFn? = {
        // RTLD_DEFAULT is `(void*)-2` on Apple platforms. Resolves against
        // the current process's loaded image set, which includes the
        // JavaScriptCore.framework dylib once `import JavaScriptCore`
        // has linked it in.
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, "JSContextGroupSetExecutionTimeLimit") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetLimitFn.self)
    }()

    /// Pins `seconds` of CPU time as the upper bound for any single
    /// invocation of script on this context's group. The callback runs
    /// when the limit is reached and returning `true` terminates the
    /// running JavaScript with a JS-side exception.
    static func install(for ctx: JSContext, seconds: Double) {
        guard let setLimit else {
            pluginLogger.warning(
                "JSContextGroupSetExecutionTimeLimit unavailable; plugins lack CPU-time cap")
            return
        }
        let group = JSContextGetGroup(ctx.jsGlobalContextRef)
        let callback: ShouldTerminateCallback = { _, _ in true }
        setLimit(group, seconds, callback, nil)
    }
}
