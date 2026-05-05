import Foundation
import JavaScriptCore
import SwiftSoup
import os

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
@MainActor
final class PluginHost {
    let context: JSContext
    private let exception = ExceptionBox()

    init(pluginSource: String) throws {
        guard let ctx = JSContext() else {
            throw PluginError.loadFailed("could not create JSContext")
        }
        self.context = ctx

        ctx.exceptionHandler = { [exception] _, value in
            exception.last = value?.toString() ?? "unknown"
            if let v = value {
                pluginLogger.error("js exception: \(v.toString() ?? "?", privacy: .public)")
            }
        }

        installConsole(in: ctx)
        installFetch(in: ctx)
        installQuerySelectorAll(in: ctx)

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
    }

    /// Calls a top-level JS function and awaits its returned Promise.
    /// `argsAsJS` are passed positionally to the call.
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
        guard let url = URL(string: urlString) else {
            throw PluginError.runtime("invalid url: \(urlString)")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
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

        let (data, response) = try await URLSession.shared.data(for: req)
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
