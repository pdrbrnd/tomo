import CryptoKit
import Foundation
import JavaScriptCore
import SwiftSoup
import os

/// Hard limits applied to every plugin. Tuning knobs in one place.
/// The four are deliberately generous — real plugin work runs in
/// milliseconds and tens of KB. The caps are airbags, not throttles.
/// Each property is `nonisolated` so background network tasks can read
/// them without an actor hop.
enum PluginLimits {
    /// CPU-time cap per JS invocation. Enforced by JavaScriptCore itself
    /// via `JSContextGroupSetExecutionTimeLimit`. Trips on `while(true){}`
    /// and the like; the script is terminated with a JS-side exception.
    nonisolated static let jsCPUSeconds: Double = 10.0
    /// Response body cap on `fetch()`. Search-result HTML is normally
    /// well under 1 MB.
    nonisolated static let fetchMaxBytes = 10 * 1024 * 1024
    /// Response body cap on `cacheImage()`. Covers are typically 0.5–2 MB.
    nonisolated static let cacheImageMaxBytes = 20 * 1024 * 1024
    /// Per-request URLSession timeout for plugin network bindings.
    nonisolated static let networkTimeoutSeconds: TimeInterval = 30
}

/// Hosts a single user-supplied JS plugin in a JavaScriptCore context.
///
/// Runtime exposed to plugins:
/// - `fetch(url, opts) -> Promise<{ status, ok, headers, body, url }>` — URLSession-backed
/// - `querySelectorAll(html, selector) -> [{ text, attrs, html }]` — SwiftSoup-backed
/// - `console.log(...)` / `console.error(...)`
///
/// JSContext is single-threaded; this class is `@MainActor` so all access
/// to `context` happens on the main actor. Async work (network, parse) happens
/// off-actor and resumes back here to call into JS.
///
/// Plugins are treated as untrusted: URL bindings are scheme-allowlisted
/// and private-host-blocked (`PluginURLValidator`); responses are size-capped;
/// CPU runs against a hard ceiling (`JSCExecutionLimit`).
@MainActor
final class PluginHost {
    let context: JSContext
    /// Read once at end of init — `var` only because the binding-install
    /// methods need `self`, which forces all stored properties to be
    /// initialized first; we can't compute the manifest before script eval.
    private(set) var manifest: PluginManifest?
    private let exception = ExceptionBox()

    init(pluginSource: String) throws {
        guard let ctx = JSContext() else {
            throw PluginError.loadFailed("could not create JSContext")
        }
        self.context = ctx
        self.manifest = nil

        // Hard CPU cap. Install before `evaluateScript` so the top-level
        // script body itself is bounded — a malicious plugin could do its
        // damage at load time, not just inside `search()`/`download()`.
        JSCExecutionLimit.install(for: ctx, seconds: PluginLimits.jsCPUSeconds)

        ctx.exceptionHandler = { [exception] _, value in
            exception.last = value?.toString() ?? "unknown"
            if let v = value {
                pluginLogger.error("js exception: \(v.toString() ?? "?", privacy: .public)")
            }
        }

        installConsole(in: ctx)
        installFetch(in: ctx)
        installQuerySelectorAll(in: ctx)
        installCacheImage(in: ctx)

        ctx.evaluateScript(pluginSource)
        if let err = exception.consume() {
            throw PluginError.loadFailed(err)
        }

        for export in ["search", "download"] {
            let val = ctx.objectForKeyedSubscript(export)
            guard let val, !val.isUndefined, val.hasProperty("call") else {
                throw PluginError.missingExport(export)
            }
        }

        self.manifest = PluginManifest.from(jsContext: ctx)
    }

    /// Calls a top-level JS function and awaits its returned Promise.
    /// `argsAsJS` are passed positionally to the call.
    ///
    /// CPU-time runaway is bounded by JSC's `JSContextGroupSetExecutionTimeLimit`
    /// (installed in `init`). A wall-clock timeout for unresolved Promises
    /// is deliberately *not* layered on top — it would require unwinding a
    /// non-cancellation-aware continuation, which Swift Concurrency can't do
    /// cleanly. A buggy plugin that forgets `resolve()` will hang its own
    /// search/download invocation forever, but cannot freeze the UI (the
    /// async wait yields the main thread).
    func invokePromise(_ functionName: String, argsAsJS: [Any]) async throws -> JSValue {
        let fn = context.objectForKeyedSubscript(functionName)
        guard let fn, !fn.isUndefined else {
            throw PluginError.missingExport(functionName)
        }
        let promise = fn.call(withArguments: argsAsJS)
        if let err = exception.consume() { throw PluginError.runtime(err) }
        guard let promise else { throw PluginError.invalidResponse }
        return try await awaitPromise(promise)
    }

    private func awaitPromise(_ promise: JSValue) async throws -> JSValue {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UncheckedJSValue, Error>) in
            let onFulfilled: @convention(block) (JSValue) -> Void = { value in
                continuation.resume(returning: UncheckedJSValue(value))
            }
            let onRejected: @convention(block) (JSValue) -> Void = { value in
                let msg = value.toString() ?? "rejected"
                continuation.resume(throwing: PluginError.runtime(msg))
            }
            guard
                let f = JSValue(object: onFulfilled, in: context),
                let r = JSValue(object: onRejected, in: context)
            else {
                continuation.resume(throwing: PluginError.invalidResponse)
                return
            }
            promise.invokeMethod("then", withArguments: [f, r])
        }.value
    }

    // MARK: - Bindings

    private func installConsole(in ctx: JSContext) {
        let log: @convention(block) (JSValue) -> Void = { value in
            pluginLogger.info("\(value.toString() ?? "", privacy: .public)")
        }
        let err: @convention(block) (JSValue) -> Void = { value in
            pluginLogger.error("\(value.toString() ?? "", privacy: .public)")
        }
        let consoleObj: [String: Any] = [
            "log": JSValue(object: log, in: ctx) as Any,
            "error": JSValue(object: err, in: ctx) as Any,
        ]
        ctx.setObject(consoleObj, forKeyedSubscript: "console" as NSString)
    }

    private func installFetch(in ctx: JSContext) {
        let fetch: @convention(block) (String, JSValue?) -> JSValue = { [weak self] url, opts in
            guard let self else { return JSValue(undefinedIn: ctx) }
            // Pre-read opts on this thread (we're on the JS thread = main).
            // JSValue isn't Sendable, so we can't capture it into the detached Task.
            let prepared = self.prepareFetchOptions(opts: opts)
            return self.makePromise(in: ctx) { resolve, reject in
                let resolveBox = UncheckedJSValue(resolve)
                let rejectBox = UncheckedJSValue(reject)
                Task.detached {
                    do {
                        let response = try await Self.performFetch(url: url, options: prepared)
                        await MainActor.run {
                            _ = resolveBox.value.call(withArguments: [response])
                        }
                    } catch {
                        await MainActor.run {
                            _ = rejectBox.value.call(withArguments: ["\(error)"])
                        }
                    }
                }
            }
        }
        ctx.setObject(fetch, forKeyedSubscript: "fetch" as NSString)
    }

    /// Pulls the JSValue-side fetch options into a Sendable bag so the network
    /// task can run off-actor without holding non-Sendable JSValues.
    private func prepareFetchOptions(opts: JSValue?) -> FetchOptions {
        guard let opts, opts.isObject else { return FetchOptions() }
        let method = opts.forProperty("method")?.toString()
        let headers = opts.forProperty("headers")?.toDictionary() as? [String: String]
        let body = opts.forProperty("body")?.toString()
        return FetchOptions(method: method, headers: headers, body: body)
    }

    private struct FetchOptions: Sendable {
        var method: String?
        var headers: [String: String]?
        var body: String?
    }

    nonisolated private static func performFetch(url urlString: String, options: FetchOptions) async throws -> [String:
        any Sendable]
    {
        let url: URL
        do {
            url = try PluginURLValidator.validateNetworkURL(urlString)
        } catch {
            throw PluginError.runtime(error.localizedDescription)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = PluginLimits.networkTimeoutSeconds
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")

        if let m = options.method { req.httpMethod = m }
        if let hs = options.headers {
            for (k, v) in hs { req.setValue(v, forHTTPHeaderField: k) }
        }
        if let b = options.body {
            req.httpBody = b.data(using: .utf8)
        }

        let (data, response) = try await PluginNetworkDelegate.run(
            request: req, maxBytes: PluginLimits.fetchMaxBytes)
        let httpResp = response as? HTTPURLResponse
        let status = httpResp?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? ""
        var headers: [String: String] = [:]
        if let allHeaders = httpResp?.allHeaderFields {
            for (k, v) in allHeaders {
                if let key = k as? String, let val = v as? String {
                    headers[key.lowercased()] = val
                }
            }
        }
        return [
            "status": status,
            "ok": (200..<300).contains(status),
            "headers": headers,
            "body": body,
            "url": httpResp?.url?.absoluteString ?? urlString,
        ]
    }

    /// `cacheImage(url, opts) -> Promise<String>` — downloads an image with
    /// caller-supplied headers (e.g. a Referer the source's hotlink check
    /// requires) and writes it to a content-addressable on-disk cache.
    /// Returns the local file path on success; rejects on non-2xx, empty
    /// response, or network error. Plugins use this when the source's own
    /// cover URL is the most authoritative cover but isn't reachable from a
    /// plain `fetch`. The plugin then assigns `coverURL = "file://" + path`
    /// so `LocalCoverImage` reads it without needing any header magic.
    private func installCacheImage(in ctx: JSContext) {
        let cacheImage: @convention(block) (String, JSValue?) -> JSValue = { [weak self] url, opts in
            guard let self else { return JSValue(undefinedIn: ctx) }
            let prepared = self.prepareCacheImageOptions(opts: opts)
            return self.makePromise(in: ctx) { resolve, reject in
                let resolveBox = UncheckedJSValue(resolve)
                let rejectBox = UncheckedJSValue(reject)
                Task.detached {
                    do {
                        let path = try await Self.fetchAndCache(url: url, options: prepared)
                        await MainActor.run {
                            _ = resolveBox.value.call(withArguments: [path])
                        }
                    } catch {
                        await MainActor.run {
                            _ = rejectBox.value.call(withArguments: ["\(error)"])
                        }
                    }
                }
            }
        }
        ctx.setObject(cacheImage, forKeyedSubscript: "cacheImage" as NSString)
    }

    private func prepareCacheImageOptions(opts: JSValue?) -> CacheImageOptions {
        guard let opts, opts.isObject else { return CacheImageOptions() }
        let referer = opts.forProperty("referer")?.toString()
        let headers = opts.forProperty("headers")?.toDictionary() as? [String: String]
        return CacheImageOptions(referer: referer, headers: headers)
    }

    private struct CacheImageOptions: Sendable {
        var referer: String?
        var headers: [String: String]?
    }

    nonisolated private static func fetchAndCache(url urlString: String, options: CacheImageOptions) async throws
        -> String
    {
        let url: URL
        do {
            url = try PluginURLValidator.validateNetworkURL(urlString)
        } catch {
            throw PluginError.runtime(error.localizedDescription)
        }
        // Content-addressable cache: ~/Library/Caches/com.pdrbrnd.tomo/plugin-covers/<sha256>.bin
        // — keyed on the URL string, so identical covers across queries reuse
        // the file. macOS auto-purges Caches under disk pressure.
        let key = sha256Hex(urlString)
        let cacheDir = try cacheDirectory()
        let cacheFile = cacheDir.appending(path: "\(key).bin")
        if FileManager.default.fileExists(atPath: cacheFile.path(percentEncoded: false)) {
            return cacheFile.path(percentEncoded: false)
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")
        if let referer = options.referer {
            req.setValue(referer, forHTTPHeaderField: "Referer")
        }
        if let headers = options.headers {
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        }

        let (data, response) = try await PluginNetworkDelegate.run(
            request: req, maxBytes: PluginLimits.cacheImageMaxBytes)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // libgen and similar serve HTTP 200 with Content-Length: 0 when the
        // cover is technically present in metadata but not actually served.
        // 100-byte floor catches that and any other near-empty response.
        guard (200..<300).contains(status), data.count > 100 else {
            throw PluginError.runtime("cacheImage status \(status), \(data.count) bytes")
        }
        try data.write(to: cacheFile, options: .atomic)
        return cacheFile.path(percentEncoded: false)
    }

    nonisolated private static func cacheDirectory() throws -> URL {
        let dir = try PluginURLValidator.coverCacheDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated private static func sha256Hex(_ s: String) -> String {
        let hash = SHA256.hash(data: Data(s.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func installQuerySelectorAll(in ctx: JSContext) {
        let qsa: @convention(block) (String, String) -> JSValue = { html, selector in
            do {
                // HTML5 parsers silently drop `<tr>`/`<td>` outside table
                // context, which breaks row-level re-parsing. If the fragment
                // starts with one of those tags, wrap it in a table so the
                // parser keeps the cells.
                let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
                let needsTableWrap = trimmed.hasPrefix("<td") || trimmed.hasPrefix("<tr") || trimmed.hasPrefix("<th")
                let toParse = needsTableWrap ? "<table>\(html)</table>" : html
                let doc = try SwiftSoup.parse(toParse)
                let elements = try doc.select(selector)
                var result: [[String: Any]] = []
                for el in elements {
                    var attrs: [String: String] = [:]
                    if let list = el.getAttributes()?.asList() {
                        for attr in list { attrs[attr.getKey()] = attr.getValue() }
                    }
                    result.append([
                        "text": (try? el.text()) ?? "",
                        "attrs": attrs,
                        "html": (try? el.html()) ?? "",
                    ])
                }
                return JSValue(object: result, in: ctx) ?? JSValue(undefinedIn: ctx)
            } catch {
                pluginLogger.error("querySelectorAll failed: \(error.localizedDescription, privacy: .public)")
                return JSValue(undefinedIn: ctx)
            }
        }
        ctx.setObject(qsa, forKeyedSubscript: "querySelectorAll" as NSString)
    }

    private func makePromise(
        in ctx: JSContext,
        executor: @escaping (_ resolve: JSValue, _ reject: JSValue) -> Void
    ) -> JSValue {
        guard let promiseCtor = ctx.objectForKeyedSubscript("Promise") else {
            return JSValue(undefinedIn: ctx)
        }
        let block: @convention(block) (JSValue, JSValue) -> Void = { resolve, reject in
            executor(resolve, reject)
        }
        guard let executorJS = JSValue(object: block, in: ctx) else {
            return JSValue(undefinedIn: ctx)
        }
        return promiseCtor.construct(withArguments: [executorJS]) ?? JSValue(undefinedIn: ctx)
    }
}

/// Captures the latest JS exception so we can surface it from an async call site.
/// JSContext's `exceptionHandler` fires synchronously during evaluation; this
/// box lets the caller pull the message out after.
final class ExceptionBox: @unchecked Sendable {
    var last: String?
    func consume() -> String? {
        defer { last = nil }
        return last
    }
}

/// Wraps a non-Sendable `JSValue` so it can cross actor boundaries.
/// The wrapper itself is Sendable, but callers are responsible for only
/// touching `.value` from the actor that owns the JSContext (always
/// MainActor in this app).
struct UncheckedJSValue: @unchecked Sendable {
    let value: JSValue
    init(_ value: JSValue) { self.value = value }
}

/// Per-task URLSession delegate for plugin network bindings. Streams the
/// response in chunks (cheap), caps total bytes, and re-validates every
/// redirect target so a public-looking URL can't 302 into `file://` or
/// `http://localhost`.
///
/// One instance per request — never reuse. `run(request:maxBytes:)` is the
/// only entry point callers should touch.
final class PluginNetworkDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private let lock = NSLock()
    private var accumulated = Data()
    private var response: URLResponse?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var settled = false
    /// When a redirect is blocked we cancel the task — but URLSession then
    /// surfaces `NSURLErrorCancelled` from `didCompleteWithError`, which
    /// hides the real reason. Stash the validation error so `settle` can
    /// prefer it over the cancellation.
    private var blockedRedirect: Error?

    private init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    /// Submit a request, await its (capped, redirect-validated) response.
    static func run(request: URLRequest, maxBytes: Int) async throws -> (Data, URLResponse) {
        let delegate = PluginNetworkDelegate(maxBytes: maxBytes)
        let task = URLSession.shared.dataTask(with: request)
        task.delegate = delegate
        return try await withCheckedThrowingContinuation { cont in
            delegate.lock.lock()
            delegate.continuation = cont
            delegate.lock.unlock()
            task.resume()
        }
    }

    /// Resume the continuation at most once and mark the request settled.
    /// Subsequent didReceive / didComplete callbacks become no-ops.
    private func settle(_ result: Result<(Data, URLResponse), Error>, cancel task: URLSessionTask?) {
        lock.lock()
        if settled {
            lock.unlock()
            return
        }
        settled = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        if let task { task.cancel() }
        switch result {
        case .success(let v): cont?.resume(returning: v)
        case .failure(let e): cont?.resume(throwing: e)
        }
    }

    // Capture the URLResponse before any body data arrives.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        self.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        accumulated.append(data)
        let exceeded = accumulated.count > maxBytes
        lock.unlock()
        if exceeded {
            settle(
                .failure(
                    PluginError.runtime(
                        "response exceeded \(maxBytes / 1024 / 1024) MB cap")),
                cancel: dataTask)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let blocked = blockedRedirect
        blockedRedirect = nil
        lock.unlock()
        if let blocked {
            settle(.failure(blocked), cancel: nil)
            return
        }
        if let error {
            settle(.failure(error), cancel: nil)
            return
        }
        lock.lock()
        let resp = response
        let acc = accumulated
        lock.unlock()
        guard let resp else {
            settle(.failure(PluginError.invalidResponse), cancel: nil)
            return
        }
        settle(.success((acc, resp)), cancel: nil)
    }

    // Completion-handler form (not async) — Swift 6.3's SILGen crashes
    // when generating the ObjC thunk for the async overload of this
    // delegate method.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url else {
            completionHandler(nil)
            return
        }
        do {
            _ = try PluginURLValidator.validateNetworkURL(url)
            completionHandler(request)
        } catch {
            pluginLogger.warning(
                "blocked plugin redirect to \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            lock.lock()
            if blockedRedirect == nil { blockedRedirect = error }
            lock.unlock()
            completionHandler(nil)
        }
    }
}
