import Foundation
import Testing

@testable import Tomo

@Suite("PluginURLValidator")
struct PluginURLValidatorTests {

    // MARK: - validateNetworkURL: scheme

    @Test func acceptsHttpAndHttps() throws {
        #expect(throws: Never.self) {
            _ = try PluginURLValidator.validateNetworkURL("http://example.com/path")
        }
        #expect(throws: Never.self) {
            _ = try PluginURLValidator.validateNetworkURL("https://example.com:8080/p?q=1")
        }
    }

    @Test func rejectsFileScheme() {
        #expect(throws: PluginURLValidator.ValidationError.self) {
            _ = try PluginURLValidator.validateNetworkURL("file:///etc/passwd")
        }
    }

    @Test func rejectsDataScheme() {
        #expect(throws: PluginURLValidator.ValidationError.self) {
            _ = try PluginURLValidator.validateNetworkURL("data:text/plain;base64,SGVsbG8=")
        }
    }

    @Test func rejectsFtpScheme() {
        #expect(throws: PluginURLValidator.ValidationError.self) {
            _ = try PluginURLValidator.validateNetworkURL("ftp://example.com/file")
        }
    }

    @Test func rejectsJavascriptScheme() {
        #expect(throws: PluginURLValidator.ValidationError.self) {
            _ = try PluginURLValidator.validateNetworkURL("javascript:alert(1)")
        }
    }

    @Test func rejectsGarbage() {
        #expect(throws: PluginURLValidator.ValidationError.self) {
            _ = try PluginURLValidator.validateNetworkURL("not a url at all")
        }
    }

    // MARK: - validateNetworkURL: private hosts

    @Test func rejectsLocalhost() {
        for host in ["http://localhost", "http://LOCALHOST", "http://localhost:8080/foo"] {
            #expect(throws: PluginURLValidator.ValidationError.self) {
                _ = try PluginURLValidator.validateNetworkURL(host)
            }
        }
    }

    @Test func rejectsMdnsLocalAndInternal() {
        #expect(throws: PluginURLValidator.ValidationError.self) {
            _ = try PluginURLValidator.validateNetworkURL("http://router.local")
        }
        #expect(throws: PluginURLValidator.ValidationError.self) {
            _ = try PluginURLValidator.validateNetworkURL("http://corp.internal")
        }
    }

    @Test func rejectsIPv4PrivateRanges() {
        let blocked = [
            "http://127.0.0.1",
            "http://127.255.255.254",
            "http://10.0.0.1",
            "http://10.255.255.255",
            "http://172.16.0.1",
            "http://172.20.5.5",
            "http://172.31.255.255",
            "http://192.168.0.1",
            "http://192.168.255.254",
            "http://169.254.169.254",
            "http://0.0.0.0",
        ]
        for url in blocked {
            #expect(throws: PluginURLValidator.ValidationError.self, "should reject \(url)") {
                _ = try PluginURLValidator.validateNetworkURL(url)
            }
        }
    }

    @Test func acceptsIPv4PublicRanges() throws {
        // 172.15.x and 172.32.x are PUBLIC — only 16..31 is private.
        // 8.8.8.8 is Google DNS — public.
        let accepted = ["http://8.8.8.8", "http://172.15.0.1", "http://172.32.0.1"]
        for url in accepted {
            #expect(throws: Never.self, "should accept \(url)") {
                _ = try PluginURLValidator.validateNetworkURL(url)
            }
        }
    }

    @Test func rejectsIPv6LoopbackAndUlaAndLinkLocal() {
        let blocked = [
            "http://[::1]/",
            "http://[fc00::1]/",
            "http://[fd00::1]/",
            "http://[fe80::1]/",
            "http://[feb0::1]/",
        ]
        for url in blocked {
            #expect(throws: PluginURLValidator.ValidationError.self, "should reject \(url)") {
                _ = try PluginURLValidator.validateNetworkURL(url)
            }
        }
    }

    // MARK: - Numeric IP normalization (SSRF bypass fixes)

    @Test func rejectsIPv4NumericEncodings() {
        // All of these collapse to 127.0.0.1 once getaddrinfo / URLSession
        // resolves them. The validator has to canonicalise via inet_aton to
        // catch them; a simple split-on-dots check misses every one.
        let blocked = [
            "http://2130706433",  // decimal 127.0.0.1
            "http://0x7f000001",  // hex
            "http://017700000001",  // octal
            "http://127.1",  // dotted-short (a.b → 127.0.0.1)
            "http://127.0.1",  // dotted-three (a.b.c)
        ]
        for url in blocked {
            #expect(throws: PluginURLValidator.ValidationError.self, "should reject \(url)") {
                _ = try PluginURLValidator.validateNetworkURL(url)
            }
        }
    }

    @Test func rejectsIPv4MappedIPv6Loopback() {
        // ::ffff:127.0.0.1 — IPv4-mapped IPv6 form of 127.0.0.1.
        // Reaches loopback at the OS level, must be blocked at the validator.
        #expect(throws: PluginURLValidator.ValidationError.self) {
            _ = try PluginURLValidator.validateNetworkURL("http://[::ffff:127.0.0.1]/")
        }
        #expect(throws: PluginURLValidator.ValidationError.self) {
            _ = try PluginURLValidator.validateNetworkURL("http://[::ffff:10.0.0.1]/")
        }
    }

    @Test func rejectsZeroExpandedIPv6Loopback() {
        // Full-form expansion of ::1. String-prefix matching misses these;
        // inet_pton canonicalises both into the same 16 bytes.
        #expect(throws: PluginURLValidator.ValidationError.self) {
            _ = try PluginURLValidator.validateNetworkURL("http://[0:0:0:0:0:0:0:1]/")
        }
    }

    @Test func acceptsPublicIPv6() throws {
        // 2606:4700::1111 — public (Cloudflare).
        #expect(throws: Never.self) {
            _ = try PluginURLValidator.validateNetworkURL("http://[2606:4700::1111]/")
        }
    }

    // MARK: - validateResultCoverURL: file:// confinement

    @Test func coverURLAcceptsHTTPS() throws {
        _ = try PluginURLValidator.validateResultCoverURL("https://covers.openlibrary.org/x.jpg")
    }

    @Test func coverURLAcceptsFileInsideCacheDirectory() throws {
        let cacheDir = try PluginURLValidator.coverCacheDirectory()
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let file = cacheDir.appending(path: "deadbeef.bin")
        try Data("fake cover".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let url = "file://" + file.path(percentEncoded: false)
        _ = try PluginURLValidator.validateResultCoverURL(url)
    }

    @Test func coverURLRejectsFileOutsideCacheDirectory() {
        #expect(throws: PluginURLValidator.ValidationError.self) {
            _ = try PluginURLValidator.validateResultCoverURL("file:///etc/passwd")
        }
        #expect(throws: PluginURLValidator.ValidationError.self) {
            _ = try PluginURLValidator.validateResultCoverURL("file:///tmp/anywhere.jpg")
        }
    }

    @Test func coverURLRejectsSymlinkEscapeFromCache() throws {
        let cacheDir = try PluginURLValidator.coverCacheDirectory()
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        // Create a symlink inside the cache directory that points at /etc/hosts.
        let link = cacheDir.appending(path: "escape.bin")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(filePath: "/etc/hosts"))
        defer { try? FileManager.default.removeItem(at: link) }
        let url = "file://" + link.path(percentEncoded: false)
        #expect(throws: PluginURLValidator.ValidationError.self) {
            _ = try PluginURLValidator.validateResultCoverURL(url)
        }
    }

    @Test func coverURLRejectsNonHTTPNonFile() {
        #expect(throws: PluginURLValidator.ValidationError.self) {
            _ = try PluginURLValidator.validateResultCoverURL("data:image/png;base64,abc")
        }
    }

    // MARK: - validateResultDetailURL

    @Test func detailURLAcceptsHTTPSOnly() throws {
        _ = try PluginURLValidator.validateResultDetailURL("https://example.com/book/123")
    }

    @Test func detailURLRejectsFile() {
        #expect(throws: PluginURLValidator.ValidationError.self) {
            _ = try PluginURLValidator.validateResultDetailURL("file:///etc/passwd")
        }
    }

    @Test func detailURLRejectsLocalhost() {
        #expect(throws: PluginURLValidator.ValidationError.self) {
            _ = try PluginURLValidator.validateResultDetailURL("http://localhost:1234")
        }
    }
}

@Suite("PluginResult URL filtering")
@MainActor
struct PluginResultURLTests {

    @Test func dropsMaliciousCoverURL() {
        let r = PluginResult.from(
            jsValue: [
                "id": "1",
                "title": "T",
                "coverURL": "file:///etc/passwd",
                "detailURL": "https://example.com/x",
            ],
            pluginID: "p")
        #expect(r != nil)
        #expect(r?.coverURL == nil)
        #expect(r?.detailURL?.absoluteString == "https://example.com/x")
    }

    @Test func dropsMaliciousDetailURL() {
        let r = PluginResult.from(
            jsValue: [
                "id": "1",
                "title": "T",
                "detailURL": "javascript:alert(1)",
            ],
            pluginID: "p")
        #expect(r?.detailURL == nil)
    }

    @Test func keepsValidHTTPSCover() {
        let r = PluginResult.from(
            jsValue: [
                "id": "1",
                "title": "T",
                "coverURL": "https://covers.openlibrary.org/x.jpg",
            ],
            pluginID: "p")
        #expect(r?.coverURL?.absoluteString == "https://covers.openlibrary.org/x.jpg")
    }
}
