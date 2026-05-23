import Foundation
import Sentry
import os

nonisolated let telemetryLogger = Logger(subsystem: "com.pdrbrnd.tomo", category: "telemetry")

/// Sentry crash + error reporting. Off-by-default in dev (no `SentryDSN`
/// in Info.plist); opt-out for users in Settings.
///
/// Tolerated background traffic, same framing as Sparkle's appcast ping:
/// the user is told it happens and can turn it off. Network breadcrumbs,
/// session tracking, and performance tracing are off — we only want
/// crashes + explicit errors.
enum CrashReporter {
    /// Stored *negated* so the default UserDefaults value (false) keeps
    /// reporting enabled. Toggling the Settings switch off sets this to
    /// true.
    private static let disabledKey = "tomo.crashReports.disabled"

    static var isEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: disabledKey) }
        set {
            UserDefaults.standard.set(!newValue, forKey: disabledKey)
            if newValue {
                start()
            } else {
                SentrySDK.close()
                telemetryLogger.info("Crash reporting disabled by user")
            }
        }
    }

    #if DEBUG
        /// Fire a non-fatal event so we can verify the pipeline (and the
        /// `beforeSend` redaction) without crashing the app.
        static func captureTestEvent() {
            let error = NSError(
                domain: "tomo.crashReporter.test",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Tomo test event from Debug menu"]
            )
            SentrySDK.capture(error: error)
            telemetryLogger.info("Sent test event to Sentry")
        }
    #endif

    static func start() {
        guard isEnabled else {
            telemetryLogger.info("Crash reporting opted out — skipping Sentry init")
            return
        }
        guard let dsn = Bundle.main.object(forInfoDictionaryKey: "SentryDSN") as? String,
            !dsn.isEmpty
        else {
            telemetryLogger.info("No SentryDSN in Info.plist — crash reporting unavailable")
            return
        }

        SentrySDK.start { options in
            options.dsn = dsn
            options.sendDefaultPii = false
            options.attachStacktrace = true
            options.enableAutoSessionTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableNetworkTracking = false
            options.enableAutoPerformanceTracing = false
            options.enableMetricKit = false
            // Tomo has no own backend — every URLSession request is
            // third-party (plugin sources, OpenLibrary, iTunes, GitHub
            // releases). Mirror failover and cover enrichment both 5xx
            // intentionally as part of normal operation. Capturing those
            // as "HTTPClientError" floods the issue list with noise that
            // isn't actionable on our side. Call sites that want to log a
            // specific HTTP failure use `SentrySDK.capture(error:)`.
            options.enableCaptureFailedRequests = false
            options.tracesSampleRate = 0
            #if DEBUG
                options.debug = true
                options.environment = "debug"
            #else
                options.environment = "release"
            #endif
            options.beforeSend = { event in
                redactUserPaths(in: event)
                return event
            }
        }
        telemetryLogger.info("Crash reporting initialized")
    }
}

/// Strip `/Users/<name>/` → `~/` from any source-path leaks in stack
/// frames, threads, and debug images. Sentry calls `beforeSend` from its
/// own queue, so this is `nonisolated`.
private nonisolated let userPathRegex = try! NSRegularExpression(pattern: "/Users/[^/]+/")

private nonisolated func redactUserPaths(in event: Event) {
    if let exceptions = event.exceptions {
        for exception in exceptions {
            redactFrames(in: exception.stacktrace)
        }
    }
    if let threads = event.threads {
        for thread in threads {
            redactFrames(in: thread.stacktrace)
        }
    }
    if let debugMeta = event.debugMeta {
        for meta in debugMeta {
            if let cf = meta.codeFile { meta.codeFile = redactedPath(cf) }
        }
    }
}

private nonisolated func redactFrames(in stacktrace: SentryStacktrace?) {
    guard let frames = stacktrace?.frames else { return }
    for frame in frames {
        if let f = frame.fileName { frame.fileName = redactedPath(f) }
        if let p = frame.package { frame.package = redactedPath(p) }
    }
}

private nonisolated func redactedPath(_ s: String) -> String {
    let range = NSRange(s.startIndex..., in: s)
    return userPathRegex.stringByReplacingMatches(in: s, range: range, withTemplate: "~/")
}
