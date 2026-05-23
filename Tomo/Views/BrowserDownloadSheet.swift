import AppKit
import SwiftUI
import WebKit

/// Probe-shape browser-driven download flow for source plugins. Opens a
/// WKWebView pointed at a source's detail page, lets the user click through
/// any Cloudflare / countdown gating manually, and captures the resulting
/// file via `WKDownload`. Hands the file path back to the caller, which
/// drives the normal import pipeline.
///
/// Today this is only surfaced as a contextual action on source rows that
/// failed to produce a free mirror (e.g. Anna's Archive when the book has
/// only slow-download partners and no IPFS/libgen mirror). If it pans out,
/// the next step is a host binding the plugin can call directly.
struct BrowserDownloadSheet: View {
    let startURL: URL
    let onCompleted: (URL) -> Void
    let onCancel: () -> Void

    @State private var status: Status = .browsing
    @State private var currentTitle: String = ""

    enum Status: Equatable {
        case browsing
        case downloading(filename: String)
        case done
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            BrowserWebView(
                startURL: startURL,
                onTitleChange: { currentTitle = $0 },
                onDownloadStarted: { filename in
                    status = .downloading(filename: filename)
                },
                onDownloadFinished: { fileURL in
                    status = .done
                    onCompleted(fileURL)
                },
                onDownloadFailed: { message in
                    status = .failed(message)
                }
            )
            Divider()
            footer
        }
        .frame(minWidth: 980, minHeight: 720)
        .background(Theme.canvas)
        .presentationBackground(Theme.canvas)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusTint)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusLabel)
                    .font(.system(size: 13, weight: .semibold))
                if !currentTitle.isEmpty {
                    Text(currentTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Text("Click through the slow-download flow. The file is captured automatically once the download starts.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statusSymbol: String {
        switch status {
        case .browsing: "globe"
        case .downloading: "arrow.down.circle"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var statusTint: Color {
        switch status {
        case .browsing, .downloading: .accentColor
        case .done: .green
        case .failed: .red
        }
    }

    private var statusLabel: String {
        switch status {
        case .browsing: "Waiting for download"
        case .downloading(let filename): "Downloading \(filename)…"
        case .done: "Download complete — importing"
        case .failed(let message): "Download failed: \(message)"
        }
    }
}

// MARK: - WKWebView wrapper

private struct BrowserWebView: NSViewRepresentable {
    let startURL: URL
    let onTitleChange: (String) -> Void
    let onDownloadStarted: (String) -> Void
    let onDownloadFinished: (URL) -> Void
    let onDownloadFailed: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onTitleChange: onTitleChange,
            onDownloadStarted: onDownloadStarted,
            onDownloadFinished: onDownloadFinished,
            onDownloadFailed: onDownloadFailed
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Persistent data store — once the user passes Cloudflare's challenge
        // for a domain, the cookie sticks across sheets and across launches.
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.observeTitle(of: webView)
        webView.load(URLRequest(url: startURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // No reactive updates — startURL is captured on first load.
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        private let onTitleChange: (String) -> Void
        private let onDownloadStarted: (String) -> Void
        private let onDownloadFinished: (URL) -> Void
        private let onDownloadFailed: (String) -> Void
        private var titleObservation: NSKeyValueObservation?
        private var downloadDir: URL?

        init(
            onTitleChange: @escaping (String) -> Void,
            onDownloadStarted: @escaping (String) -> Void,
            onDownloadFinished: @escaping (URL) -> Void,
            onDownloadFailed: @escaping (String) -> Void
        ) {
            self.onTitleChange = onTitleChange
            self.onDownloadStarted = onDownloadStarted
            self.onDownloadFinished = onDownloadFinished
            self.onDownloadFailed = onDownloadFailed
        }

        func observeTitle(of webView: WKWebView) {
            titleObservation = webView.observe(\.title, options: [.initial, .new]) { [weak self] _, change in
                let title = change.newValue.flatMap { $0 } ?? ""
                Task { @MainActor in
                    self?.onTitleChange(title)
                }
            }
        }

        // MARK: WKNavigationDelegate — promote attachment-shaped responses to downloads

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse
        ) async -> WKNavigationResponsePolicy {
            shouldDownload(navigationResponse.response) ? .download : .allow
        }

        func webView(
            _ webView: WKWebView,
            navigationResponse: WKNavigationResponse,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        // Some sites trigger downloads via the navigation action (e.g. an
        // <a> with `download` attribute, or a JS-initiated navigation to a
        // file URL). Cover that path too.
        func webView(
            _ webView: WKWebView,
            navigationAction: WKNavigationAction,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        // Allow links targeting a new window to open in the same webview.
        // AA's slow-download links sometimes carry target="_blank".
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        // MARK: WKDownloadDelegate

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String
        ) async -> URL? {
            let safeName = suggestedFilename.isEmpty ? "download.bin" : suggestedFilename
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tomo-browser-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                onDownloadFailed("Couldn't create temp directory: \(error.localizedDescription)")
                return nil
            }
            downloadDir = dir
            onDownloadStarted(safeName)
            return dir.appendingPathComponent(safeName)
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let dir = downloadDir,
                let file = try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil
                ).first
            else {
                onDownloadFailed("Download finished but file is missing")
                return
            }
            onDownloadFinished(file)
        }

        func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
            onDownloadFailed(error.localizedDescription)
        }

        private func shouldDownload(_ response: URLResponse) -> Bool {
            if let http = response as? HTTPURLResponse {
                let disposition = (http.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
                if disposition.contains("attachment") {
                    return true
                }
            }
            switch (response.mimeType ?? "").lowercased() {
            case "application/epub+zip",
                "application/octet-stream",
                "application/x-mobipocket-ebook",
                "application/vnd.amazon.ebook":
                return true
            default:
                return false
            }
        }
    }
}
