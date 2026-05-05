import CryptoKit
import Foundation
import JavaScriptCore
import SwiftSoup

enum PluginError: Error, CustomStringConvertible {
    case loadFailed(String)
    case missingExport(String)
    case runtime(String)
    case invalidResponse

    var description: String {
        switch self {
        case .loadFailed(let m): return "plugin load failed: \(m)"
        case .missingExport(let m): return "plugin missing export: \(m)"
        case .runtime(let m): return "plugin runtime error: \(m)"
        case .invalidResponse: return "plugin returned invalid response shape"
        }
    }
}

@MainActor
final class PluginHost {
    private let context: JSContext
    private let exception = ExceptionBox()

    init(pluginSource: String) throws {
        guard let ctx = JSContext() else {
            throw PluginError.loadFailed("could not create JSContext")
        }
        self.context = ctx

        ctx.exceptionHandler = { [exception] _, value in
            exception.last = value?.toString() ?? "unknown"
            if let v = value { fputs("[js exception] \(v)\n", stderr) }
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
            if val == nil || val!.isUndefined || !val!.hasProperty("call") {
                throw PluginError.missingExport(export)
            }
        }
    }

    func search(query: [String: Any]) async throws -> [[String: Any]] {
        let promise = context.objectForKeyedSubscript("search").call(withArguments: [query])
        if let err = exception.consume() { throw PluginError.runtime(err) }
        guard let promise else { throw PluginError.invalidResponse }
        let resolved = try await awaitPromise(promise)
        guard let arr = resolved.toArray() as? [[String: Any]] else {
            throw PluginError.invalidResponse
        }
        return arr
    }

    func download(result: [String: Any]) async throws -> String {
        let promise = context.objectForKeyedSubscript("download").call(withArguments: [result])
        if let err = exception.consume() { throw PluginError.runtime(err) }
        guard let promise else { throw PluginError.invalidResponse }
        let resolved = try await awaitPromise(promise)
        guard let url = resolved.toString(), !url.isEmpty else {
            throw PluginError.invalidResponse
        }
        return url
    }

    private func awaitPromise(_ promise: JSValue) async throws -> JSValue {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSValue, Error>) in
            let onFulfilled: @convention(block) (JSValue) -> Void = { value in
                continuation.resume(returning: value)
            }
            let onRejected: @convention(block) (JSValue) -> Void = { value in
                continuation.resume(throwing: PluginError.runtime(value.toString() ?? "rejected"))
            }
            let f = JSValue(object: onFulfilled, in: context)!
            let r = JSValue(object: onRejected, in: context)!
            promise.invokeMethod("then", withArguments: [f, r])
        }
    }

    // MARK: - Bindings

    private func installConsole(in ctx: JSContext) {
        let log: @convention(block) (JSValue) -> Void = { value in
            let str = value.toString() ?? ""
            print("[plugin] \(str)")
        }
        let err: @convention(block) (JSValue) -> Void = { value in
            let str = value.toString() ?? ""
            fputs("[plugin err] \(str)\n", stderr)
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
            return self.makePromise(in: ctx) { resolve, reject in
                Task.detached {
                    do {
                        let response = try await self.performFetch(url: url, opts: opts)
                        await MainActor.run {
                            resolve.call(withArguments: [response])
                        }
                    } catch {
                        await MainActor.run {
                            reject.call(withArguments: ["\(error)"])
                        }
                    }
                }
            }
        }
        ctx.setObject(fetch, forKeyedSubscript: "fetch" as NSString)
    }

    private func performFetch(url urlString: String, opts: JSValue?) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else {
            throw PluginError.runtime("invalid url: \(urlString)")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")

        if let opts, opts.isObject {
            if let method = opts.forProperty("method"), method.isString {
                req.httpMethod = method.toString()
            }
            if let headers = opts.forProperty("headers"), headers.isObject,
                let dict = headers.toDictionary() as? [String: String]
            {
                for (k, v) in dict { req.setValue(v, forHTTPHeaderField: k) }
            }
            if let body = opts.forProperty("body"), body.isString,
                let bodyStr = body.toString()
            {
                req.httpBody = bodyStr.data(using: .utf8)
            }
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
        let finalURL = httpResp?.url?.absoluteString ?? urlString
        return [
            "status": status,
            "ok": (200..<300).contains(status),
            "headers": headers,
            "body": body,
            "url": finalURL,
        ]
    }

    /// Mirror of the app-side `cacheImage` binding. Downloads bytes with
    /// caller-supplied headers (e.g. Referer for hotlink-protected covers)
    /// and caches them on disk. Returns the local file path. Plugins use
    /// this when a source's own cover URL is the most authoritative cover
    /// but the server requires a Referer to actually serve the bytes.
    private func installCacheImage(in ctx: JSContext) {
        let cacheImage: @convention(block) (String, JSValue?) -> JSValue = { [weak self] url, opts in
            guard let self else { return JSValue(undefinedIn: ctx) }
            let prepared = self.prepareCacheImageOptions(opts: opts)
            return self.makePromise(in: ctx) { resolve, reject in
                Task.detached {
                    do {
                        let path = try await Self.fetchAndCache(url: url, options: prepared)
                        await MainActor.run {
                            resolve.call(withArguments: [path])
                        }
                    } catch {
                        await MainActor.run {
                            reject.call(withArguments: ["\(error)"])
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
        guard let url = URL(string: urlString) else {
            throw PluginError.runtime("invalid url: \(urlString)")
        }
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
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), data.count > 100 else {
            throw PluginError.runtime("cacheImage status \(status), \(data.count) bytes")
        }
        try data.write(to: cacheFile, options: .atomic)
        return cacheFile.path(percentEncoded: false)
    }

    nonisolated private static func cacheDirectory() throws -> URL {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw PluginError.runtime("no cache directory available")
        }
        let dir =
            base
            .appending(path: "com.pdrbrnd.tomo", directoryHint: .isDirectory)
            .appending(path: "plugin-covers", directoryHint: .isDirectory)
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
                return JSValue(undefinedIn: ctx)
            }
        }
        ctx.setObject(qsa, forKeyedSubscript: "querySelectorAll" as NSString)
    }

    private func makePromise(
        in ctx: JSContext,
        executor: @escaping (_ resolve: JSValue, _ reject: JSValue) -> Void
    ) -> JSValue {
        let promiseCtor = ctx.objectForKeyedSubscript("Promise")!
        let block: @convention(block) (JSValue, JSValue) -> Void = { resolve, reject in
            executor(resolve, reject)
        }
        let executorJS = JSValue(object: block, in: ctx)!
        return promiseCtor.construct(withArguments: [executorJS]) ?? JSValue(undefinedIn: ctx)
    }
}

/// Captures the latest JS exception so we can surface it from an async resume.
final class ExceptionBox: @unchecked Sendable {
    var last: String?
    func consume() -> String? {
        defer { last = nil }
        return last
    }
}
