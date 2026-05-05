import Foundation

@MainActor
func runSpike() async {
    let args = CommandLine.arguments
    let pluginName = ProcessInfo.processInfo.environment["PLUGIN"] ?? "anna"
    let pluginPath = "\(FileManager.default.currentDirectoryPath)/plugins/\(pluginName).js"
    print("plugin: \(pluginPath)")

    guard FileManager.default.fileExists(atPath: pluginPath) else {
        fputs("error: no plugin at \(pluginPath)\n", stderr)
        exit(1)
    }
    let source: String
    do {
        source = try String(contentsOfFile: pluginPath, encoding: .utf8)
    } catch {
        fputs("error reading plugin: \(error)\n", stderr)
        exit(1)
    }

    let host: PluginHost
    do {
        host = try PluginHost(pluginSource: source)
    } catch {
        fputs("plugin init failed: \(error)\n", stderr)
        exit(1)
    }

    let command = args.count > 1 ? args[1] : "search"

    switch command {
    case "search":
        let queryText = args.count > 2 ? args[2] : "saramago"
        await runSearch(host: host, query: queryText)
    case "download":
        let queryText = args.count > 2 ? args[2] : "saramago"
        await runDownload(host: host, query: queryText)
    case "smoke":
        await runSmoke(host: host)
    case "browser":
        let queryText = args.count > 2 ? args[2] : "saramago"
        await runBrowser(query: queryText)
    default:
        fputs("usage: JSCoreSpike [search|download|smoke|browser] [query]\n", stderr)
        exit(2)
    }
}

@MainActor
func runSearch(host: PluginHost, query: String) async {
    print("→ search(\"\(query)\")")
    do {
        let results = try await host.search(query: ["text": query])
        print("← \(results.count) results")
        for (i, r) in results.prefix(10).enumerated() {
            let title = r["title"] as? String ?? "?"
            let authors = (r["authors"] as? [String])?.joined(separator: ", ") ?? "?"
            let year = (r["year"] as? Int).map { "\($0)" } ?? "—"
            let lang = r["language"] as? String ?? "—"
            let format = r["format"] as? String ?? "—"
            let size = (r["sizeBytes"] as? Int).map { "\($0/1024) KB" } ?? "—"
            let cover = (r["coverURL"] as? String).map { String($0.suffix(50)) } ?? "—"
            print("  [\(i)] \(title) — \(authors) (\(year)) [\(lang)] \(format) \(size) cover:\(cover)")
        }
        if results.count > 10 {
            print("  … and \(results.count - 10) more")
        }
    } catch {
        fputs("search failed: \(error)\n", stderr)
        exit(1)
    }
}

@MainActor
func runDownload(host: PluginHost, query: String) async {
    print("→ search(\"\(query)\")")
    let results: [[String: Any]]
    do {
        results = try await host.search(query: ["text": query])
    } catch {
        fputs("search failed: \(error)\n", stderr)
        exit(1)
    }
    guard let first = results.first else {
        fputs("no results\n", stderr)
        exit(1)
    }
    let title = first["title"] as? String ?? "?"
    print("→ download(first result: \(title))")
    do {
        let url = try await host.download(result: first)
        print("← download URL: \(url)")
        try await fetchAndSave(url: url, hint: first["format"] as? String ?? "epub")
    } catch {
        fputs("download failed: \(error)\n", stderr)
        exit(1)
    }
}

@MainActor
func runSmoke(host: PluginHost) async {
    print("smoke check — plugin loaded, exports present.")
    print("(use 'search <query>' or 'download <query>' next.)")
    _ = host
}

func fetchAndSave(url urlString: String, hint: String) async throws {
    guard let url = URL(string: urlString) else {
        throw PluginError.runtime("invalid download URL: \(urlString)")
    }
    print("→ GET \(url)")
    var req = URLRequest(url: url)
    req.timeoutInterval = 60
    req.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        forHTTPHeaderField: "User-Agent")
    let (tempURL, response) = try await URLSession.shared.download(for: req)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let httpResp = response as? HTTPURLResponse
    let status = httpResp?.statusCode ?? 0
    let bytes = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int) ?? 0
    print("← status \(status), \(bytes) bytes")
    guard (200..<300).contains(status), bytes > 0 else {
        throw PluginError.runtime("non-success download: status=\(status), bytes=\(bytes)")
    }

    let ext = (hint.isEmpty ? "bin" : hint).lowercased()
    let dest = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("downloaded.\(ext)")
    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.moveItem(at: tempURL, to: dest)
    print("✓ wrote \(dest.path) (\(bytes) bytes)")

    if ext == "epub" {
        // EPUB = ZIP, magic bytes "PK\x03\x04"
        let handle = try FileHandle(forReadingFrom: dest)
        let head = try handle.read(upToCount: 4) ?? Data()
        try handle.close()
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            print("✓ valid ZIP magic — looks like a real EPUB")
        } else {
            print("⚠ not a ZIP — first 4 bytes: \(head.map { String(format: "%02x", $0) }.joined(separator: " "))")
        }
    }
}

await runSpike()
