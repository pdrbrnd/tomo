import AppKit
import SwiftUI
import WebKit
import os

// MARK: - Resource loader

/// Serves the book to a `WKWebView`: the single merged document at
/// `tomo-epub://book/__reader__`, and every image lazily out of the zip via
/// `EPUBArchive.data(at:)` — no upfront extraction, no temp-dir copy.
@MainActor
final class EPUBResourceLoader: NSObject, WKURLSchemeHandler {
    private let archive: EPUBArchive
    private let document: Data
    /// Archive-absolute resource path → declared media type, from the OPF
    /// manifest. Falls back to extension inference for anything unlisted.
    private let mimeByPath: [String: String]

    init(archive: EPUBArchive, combinedHTML: String) {
        self.archive = archive
        self.document = Data(combinedHTML.utf8)
        var map: [String: String] = [:]
        for item in archive.opf.manifest where !item.mediaType.isEmpty {
            map[EPUBArchive.resolvePath(item.href, baseDir: archive.opfDir)] = item.mediaType
        }
        self.mimeByPath = map
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
            let path = EPUBReaderScheme.archivePath(from: url)
        else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let data: Data
        let mime: String
        if path == EPUBReaderScheme.documentPath {
            data = document
            mime = "text/html"
        } else if let bytes = archive.data(at: path) {
            data = bytes
            mime = mimeByPath[path] ?? Self.inferredMIME(forPath: path)
        } else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": String(data.count)]
        )!
        // Synchronous completion: no race with `stop`, which WebKit only sends
        // for tasks still in flight.
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private static func inferredMIME(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        case "css": "text/css"
        default: "application/octet-stream"
        }
    }
}

// MARK: - Reader model

/// Owns the resource loader (and through it the opened archive) and the table
/// of contents. Built once per book.
@MainActor
final class EPUBReaderModel {
    let loader: EPUBResourceLoader
    let toc: [ReaderTOCItem]

    init(content: EPUBReaderContent, archive: EPUBArchive) {
        self.loader = EPUBResourceLoader(archive: archive, combinedHTML: content.html)
        self.toc = content.toc
    }
}

/// A one-shot request to scroll the reader to a chapter anchor. The `id`
/// makes each tap distinct so selecting the same chapter twice still scrolls.
struct ScrollRequest: Equatable {
    let anchor: String
    let id = UUID()
}

// MARK: - Reader view

/// Whole-book continuous-scroll reader. One merged, self-styled document; the
/// only chrome is the floating contents control (and the system traffic
/// lights). No pagination, by design — see the reading-feature plan.
struct EPUBReaderView: View {
    let fileURL: URL
    let bookID: UUID?
    let title: String

    @State private var model: EPUBReaderModel?
    @State private var phase: LoadPhase = .loading
    @State private var scrollFraction: Double = 0
    @State private var initialFraction: Double = 0
    @State private var showTOC = false
    @State private var scrollRequest: ScrollRequest?
    @State private var hoveringContents = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Matches the app's panel motion vocabulary (see the inspector +
    /// `selectionAnimation` in `LibraryView`).
    private var panelAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .spring(duration: 0.34, bounce: 0.12)
    }

    private enum LoadPhase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ReaderMessage(systemImage: "book", text: "Opening…")
            case .failed(let message):
                ReaderMessage(systemImage: "exclamationmark.triangle", text: message)
            case .ready:
                if let model { reader(model) }
            }
        }
        .task(id: fileURL) { await load() }
        .onDisappear { savePosition() }
    }

    // MARK: Loading

    private func load() async {
        phase = .loading
        do {
            try await CoordinatedRead.ensureDownloaded(fileURL)
            let content = try await Task.detached(priority: .userInitiated) {
                try EPUBReaderContent.build(fileURL: fileURL)
            }.value
            let archive = try EPUBArchive.open(fileURL)
            let saved = bookID.flatMap { ReadingPositionStore.position(for: $0) }
            self.model = EPUBReaderModel(content: content, archive: archive)
            self.initialFraction = saved?.scrollFraction ?? 0
            self.scrollFraction = saved?.scrollFraction ?? 0
            self.phase = .ready
        } catch let error as EPUBArchiveError {
            phase = .failed(error.errorDescription ?? "Couldn't open this book.")
        } catch let error as CoordinatedReadError {
            phase = .failed(error.errorDescription ?? "Couldn't open this book.")
        } catch {
            readerLogger.error("epub open failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed("Couldn't open this book.")
        }
    }

    // MARK: Reader

    private func reader(_ model: EPUBReaderModel) -> some View {
        ZStack(alignment: .topTrailing) {
            EPUBWebView(
                loader: model.loader,
                initialScrollFraction: initialFraction,
                scrollRequest: scrollRequest,
                onScroll: { scrollFraction = $0 }
            )
            .ignoresSafeArea()
            // Drag the window by its edges; the centre still scrolls/selects.
            .overlay(WindowEdgeDragRegion().ignoresSafeArea())

            progressLine
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            // Scrim and panel are inserted as direct siblings so each carries
            // its own transition — a `.move` on a child of a conditionally
            // inserted container only ever fades.
            if showTOC, !model.toc.isEmpty {
                scrim
                    .transition(.opacity)
                tocPanel(model)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if !model.toc.isEmpty {
                contentsButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    private var progressLine: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(.primary.opacity(0.28))
                .frame(width: max(0, min(1, scrollFraction)) * geo.size.width, height: 2)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }

    private var contentsButton: some View {
        Button {
            withAnimation(panelAnimation) { showTOC.toggle() }
        } label: {
            Image(systemName: showTOC ? "xmark" : "list.bullet")
                .font(.system(size: 13, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                // Snappy icon swap, independent of the slower panel spring.
                .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: showTOC)
                .frame(width: Theme.Chrome.toggleDiameter, height: Theme.Chrome.toggleDiameter)
                .background(Theme.overlaySurface, in: Circle())
                .overlay(Circle().stroke(Theme.hairline, lineWidth: 0.5))
                .softShadow(elevated: false)
                .scaleEffect(hoveringContents ? 1.07 : 1)
        }
        .buttonStyle(.plain)
        .help(showTOC ? "Hide contents" : "Contents")
        .onHover { hovering in
            withAnimation(.spring(duration: 0.28, bounce: 0.2)) { hoveringContents = hovering }
        }
        // Sit just below the offset traffic-light row, top-right.
        .padding(.top, Theme.Chrome.toggleEdgeInset)
        .padding(.trailing, Theme.Chrome.toggleEdgeInset)
    }

    private var scrim: some View {
        Color.black.opacity(0.001)
            .ignoresSafeArea()
            .onTapGesture { withAnimation(panelAnimation) { showTOC = false } }
    }

    private func tocPanel(_ model: EPUBReaderModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Contents")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(Theme.Text.emphatic))
                // Align with the rows' text (row inset = menuInset + 12).
                .padding(.leading, Theme.Spacing.md + Theme.Spacing.menuInset)
                // Clear the close button overlapping the top-right corner.
                .padding(.trailing, Theme.Chrome.toggleDiameter + Theme.Spacing.sm)
                .padding(.top, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.sm)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.toc) { entry in
                        Button {
                            scrollRequest = ScrollRequest(anchor: entry.anchor)
                            withAnimation(panelAnimation) { showTOC = false }
                        } label: {
                            Text(entry.title)
                                .font(.system(size: 13))
                                .foregroundStyle(.primary.opacity(Theme.Text.muted))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(SidebarRowStyle(isSelected: false))
                    }
                }
                .padding(.bottom, Theme.Spacing.md)
            }
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 0.5)
        )
        .paneShadow()
        .padding(Theme.Chrome.paneInset)
    }

    // MARK: Persistence

    private func savePosition() {
        guard let bookID else { return }
        ReadingPositionStore.save(
            ReadingPosition(scrollFraction: scrollFraction), for: bookID)
    }
}

// MARK: - Shared message view

private struct ReaderMessage: View {
    let systemImage: String
    let text: String

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.primary.opacity(Theme.Text.tertiary))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(Theme.Text.secondary))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.xxl)
    }
}

// MARK: - WebKit bridge

private struct EPUBWebView: NSViewRepresentable {
    let loader: EPUBResourceLoader
    let initialScrollFraction: Double
    let scrollRequest: ScrollRequest?
    let onScroll: (Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(initialScrollFraction: initialScrollFraction, onScroll: onScroll)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(loader, forURLScheme: EPUBReaderScheme.scheme)

        let controller = WKUserContentController()
        controller.addUserScript(
            WKUserScript(
                source: Self.scrollReporterScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true))
        controller.add(context.coordinator, name: "tomoScroll")
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = NSColor(name: nil) { appearance in
            if isDarkAppearance(appearance) {
                return NSColor(srgbRed: 0.062, green: 0.062, blue: 0.066, alpha: 1.0)
            }
            return NSColor(srgbRed: 0.965, green: 0.961, blue: 0.953, alpha: 1.0)
        }

        if let url = EPUBReaderScheme.documentURL {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onScroll = onScroll
        if let request = scrollRequest, request.id != context.coordinator.lastScrollRequestID {
            context.coordinator.lastScrollRequestID = request.id
            context.coordinator.scroll(webView, toAnchor: request.anchor)
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeAllUserScripts()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "tomoScroll")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onScroll: (Double) -> Void
        var lastScrollRequestID: UUID?

        private let initialScrollFraction: Double
        private var didRestoreInitial = false

        init(initialScrollFraction: Double, onScroll: @escaping (Double) -> Void) {
            self.initialScrollFraction = initialScrollFraction
            self.onScroll = onScroll
        }

        func scroll(_ webView: WKWebView, toAnchor anchor: String) {
            let js = """
                (function(){
                  var e = document.getElementById('\(anchor)');
                  if (e) e.scrollIntoView({ behavior: 'smooth', block: 'start' });
                })();
                """
            webView.evaluateJavaScript(js)
        }

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard message.name == "tomoScroll", let fraction = message.body as? Double else {
                return
            }
            onScroll(fraction)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            // Only external links navigate away; everything in-document
            // (initial load, #anchors, images) stays.
            guard navigationAction.navigationType == .linkActivated,
                let url = navigationAction.request.url,
                let scheme = url.scheme,
                ["http", "https", "mailto", "tel"].contains(scheme.lowercased())
            else {
                return .allow
            }
            NSWorkspace.shared.open(url)
            return .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !didRestoreInitial else { return }
            didRestoreInitial = true
            guard initialScrollFraction > 0 else { return }
            let js = """
                (function(){
                  var h = document.documentElement.scrollHeight - window.innerHeight;
                  if (h > 0) window.scrollTo(0, h * \(initialScrollFraction));
                })();
                """
            webView.evaluateJavaScript(js)
        }
    }

    private static let scrollReporterScript = """
        (function(){
          function fraction(){
            var h = document.documentElement.scrollHeight - window.innerHeight;
            return h > 0 ? Math.min(1, Math.max(0, window.scrollY / h)) : 0;
          }
          var ticking = false;
          function report(){
            ticking = false;
            try { window.webkit.messageHandlers.tomoScroll.postMessage(fraction()); } catch(e){}
          }
          window.addEventListener('scroll', function(){
            if (!ticking) { ticking = true; requestAnimationFrame(report); }
          }, { passive: true });
          report();
        })();
        """
}
