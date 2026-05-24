import Darwin
import Foundation

/// Validates URLs that flow through the plugin system. Pure, nonisolated —
/// safe to call from any thread / actor. All entry points return a
/// canonicalised `URL` on success; throw `ValidationError` otherwise.
///
/// Three flavours:
/// - `validateNetworkURL` — `http(s)` only, host not private. For `fetch()`
///   and `cacheImage()` bindings + their redirect targets.
/// - `validateResultCoverURL` — same as network, OR `file://` confined to
///   the plugin cover cache directory. Plugins write covers via
///   `cacheImage()` (which returns a file path) and then surface that path
///   back in `coverURL`; this validator lets that round-trip work without
///   opening the door to arbitrary `file://` reads.
/// - `validateResultDetailURL` — `http(s)` only. Plugins surface these so
///   the host can open them in Safari / the in-app browser.
nonisolated enum PluginURLValidator {
    enum ValidationError: Error, LocalizedError {
        case invalidURL(String)
        case unsupportedScheme(String)
        case privateHost(String)
        case outsideCacheDirectory(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL(let s): "Invalid URL: \(s)"
            case .unsupportedScheme(let s): "Blocked URL scheme: \(s)"
            case .privateHost(let s): "Blocked private host: \(s)"
            case .outsideCacheDirectory(let s): "file:// URL outside plugin cache: \(s)"
            }
        }
    }

    static func validateNetworkURL(_ urlString: String) throws -> URL {
        guard let url = URL(string: urlString) else {
            throw ValidationError.invalidURL(urlString)
        }
        return try validateNetworkURL(url)
    }

    static func validateNetworkURL(_ url: URL) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ValidationError.unsupportedScheme(url.scheme ?? "")
        }
        guard let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            throw ValidationError.invalidURL(url.absoluteString)
        }
        if isPrivateHost(host) {
            throw ValidationError.privateHost(host)
        }
        return url
    }

    static func validateResultCoverURL(_ urlString: String) throws -> URL {
        guard let url = URL(string: urlString) else {
            throw ValidationError.invalidURL(urlString)
        }
        if url.scheme?.lowercased() == "file" {
            return try validateCacheFileURL(url)
        }
        return try validateNetworkURL(url)
    }

    static func validateResultDetailURL(_ urlString: String) throws -> URL {
        try validateNetworkURL(urlString)
    }

    /// The directory `cacheImage()` writes to and `validateResultCoverURL`
    /// accepts. Single source of truth for both sides of the round-trip;
    /// `PluginHost` calls this then ensures the directory exists.
    static func coverCacheDirectory() throws -> URL {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw ValidationError.outsideCacheDirectory("no cache directory available")
        }
        return
            base
            .appending(path: "com.pdrbrnd.tomo", directoryHint: .isDirectory)
            .appending(path: "plugin-covers", directoryHint: .isDirectory)
    }

    // MARK: - Private host check

    /// Returns true if `host` resolves (as a literal — no DNS) to an address
    /// inside a private / loopback / link-local range, OR matches a hostname
    /// pattern we treat as "internal" (`localhost`, `*.local`, `*.internal`).
    ///
    /// Numeric IPv4 goes through `inet_aton` rather than string-splitting on
    /// dots because URLSession's getaddrinfo will happily accept the legacy
    /// non-canonical forms — `127.1`, `2130706433`, `0x7f000001`,
    /// `017700000001` — all of which collapse to 127.0.0.1. Same idea for
    /// IPv6: `inet_pton(AF_INET6, ...)` canonicalises zero-compression and
    /// IPv4-mapped forms (`::ffff:127.0.0.1`) into 16 raw bytes we can
    /// classify cleanly.
    private static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" { return true }
        if host.hasSuffix(".local") || host.hasSuffix(".internal") { return true }

        if let octets = ipv4OctetsLenient(host) {
            return ipv4IsPrivate(octets)
        }
        if let bytes = ipv6Bytes(host) {
            return ipv6IsPrivate(bytes)
        }
        return false
    }

    /// Decodes any IPv4 literal `inet_aton` accepts: dotted-quad, `a.b.c`,
    /// `a.b`, single decimal, hex (`0x`), octal (leading `0`). Returns the
    /// four octets in host order, or nil if not a numeric IPv4.
    private static func ipv4OctetsLenient(_ host: String) -> [Int]? {
        var addr = in_addr()
        guard host.withCString({ inet_aton($0, &addr) }) != 0 else { return nil }
        let hostOrder = UInt32(bigEndian: addr.s_addr)
        return [
            Int((hostOrder >> 24) & 0xff),
            Int((hostOrder >> 16) & 0xff),
            Int((hostOrder >> 8) & 0xff),
            Int(hostOrder & 0xff),
        ]
    }

    /// Returns the 16-byte canonical representation of `host` if it parses as
    /// an IPv6 literal (brackets tolerated). Otherwise nil.
    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        let stripped = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var addr = in6_addr()
        guard stripped.withCString({ inet_pton(AF_INET6, $0, &addr) }) > 0 else { return nil }
        return withUnsafeBytes(of: addr) { Array($0) }
    }

    private static func ipv4IsPrivate(_ o: [Int]) -> Bool {
        if o[0] == 0 { return true }  // 0.0.0.0/8
        if o[0] == 10 { return true }  // 10.0.0.0/8
        if o[0] == 127 { return true }  // 127.0.0.0/8
        if o[0] == 169 && o[1] == 254 { return true }  // 169.254.0.0/16
        if o[0] == 172 && (16...31).contains(o[1]) { return true }  // 172.16.0.0/12
        if o[0] == 192 && o[1] == 168 { return true }  // 192.168.0.0/16
        return false
    }

    private static func ipv6IsPrivate(_ b: [UInt8]) -> Bool {
        // ::1 loopback — all zero except the final byte = 1.
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }
        // IPv4-mapped IPv6 (`::ffff:a.b.c.d`) — classify the embedded v4.
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
            return ipv4IsPrivate([Int(b[12]), Int(b[13]), Int(b[14]), Int(b[15])])
        }
        // fc00::/7 (ULA) — top 7 bits == 1111 110.
        if (b[0] & 0xfe) == 0xfc { return true }
        // fe80::/10 (link-local) — first byte 0xfe, next byte top 2 bits = 10.
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }
        return false
    }

    // MARK: - file:// confinement

    private static func validateCacheFileURL(_ url: URL) throws -> URL {
        guard url.isFileURL else {
            throw ValidationError.invalidURL(url.absoluteString)
        }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let cacheDir: URL
        do {
            cacheDir = try coverCacheDirectory().standardizedFileURL.resolvingSymlinksInPath()
        } catch {
            throw ValidationError.outsideCacheDirectory(url.path(percentEncoded: false))
        }
        let resolvedPath = resolved.path(percentEncoded: false)
        let cachePath = cacheDir.path(percentEncoded: false)
        // Trailing slash prevents "/foo/plugin-covers-evil" from matching
        // "/foo/plugin-covers" via raw hasPrefix.
        let cachePrefix = cachePath.hasSuffix("/") ? cachePath : cachePath + "/"
        guard resolvedPath.hasPrefix(cachePrefix) else {
            throw ValidationError.outsideCacheDirectory(resolvedPath)
        }
        return resolved
    }
}
