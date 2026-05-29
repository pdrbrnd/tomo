import AppKit
import PDFKit
import SwiftUI
import os

/// PDF reader: PDFKit's continuous-scroll viewer, the file loaded in place
/// (no import), with remembered page. A thin top bar carries the title and
/// clears the offset traffic lights.
struct PDFReaderScreen: View {
    let fileURL: URL
    let bookID: UUID?
    let title: String

    @State private var phase: LoadPhase = .loading

    private enum LoadPhase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    var body: some View {
        content
            .task(id: fileURL) { await ensureAvailable() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            placeholder("doc", "Opening…")
        case .failed(let message):
            placeholder("exclamationmark.triangle", message)
        case .ready:
            PDFDocumentView(fileURL: fileURL, bookID: bookID)
                // Drag the window by its edges; the centre still scrolls.
                .overlay(WindowEdgeDragRegion().ignoresSafeArea())
        }
    }

    private func placeholder(_ systemImage: String, _ text: String) -> some View {
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

    private func ensureAvailable() async {
        phase = .loading
        do {
            try await CoordinatedRead.ensureDownloaded(fileURL)
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

private struct PDFDocumentView: NSViewRepresentable {
    let fileURL: URL
    let bookID: UUID?

    func makeCoordinator() -> Coordinator { Coordinator(bookID: bookID) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        context.coordinator.attach(to: view)
        context.coordinator.load(fileURL, into: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.loadedURL != fileURL {
            context.coordinator.load(fileURL, into: view)
        }
    }

    @MainActor
    final class Coordinator {
        let bookID: UUID?
        var loadedURL: URL?
        private weak var pdfView: PDFView?
        nonisolated(unsafe) var observer: NSObjectProtocol?

        init(bookID: UUID?) { self.bookID = bookID }

        nonisolated deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func attach(to view: PDFView) {
            pdfView = view
            observer = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.savePage() }
            }
        }

        func load(_ url: URL, into view: PDFView) {
            loadedURL = url
            guard let document = PDFDocument(url: url) else {
                readerLogger.error("pdf open failed: \(url.lastPathComponent, privacy: .public)")
                return
            }
            view.document = document
            guard let bookID,
                let saved = ReadingPositionStore.position(for: bookID),
                document.pageCount > 0,
                let page = document.page(at: min(max(saved.pageIndex, 0), document.pageCount - 1))
            else { return }
            view.go(to: page)
        }

        private func savePage() {
            guard let bookID,
                let view = pdfView,
                let document = view.document,
                let current = view.currentPage
            else { return }
            let index = document.index(for: current)
            ReadingPositionStore.save(ReadingPosition(pageIndex: index), for: bookID)
        }
    }
}
