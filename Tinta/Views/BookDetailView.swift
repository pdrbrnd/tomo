import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct BookDetailView: View {
    let book: Book
    let state: AppState
    @State private var showingEdit = false
    @State private var showingCoverPicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                Form {
                    Section {
                        languageRow
                        LabeledContent("Date added", value: book.dateAdded.formatted(.dateTime.year().month().day()))
                        LabeledContent("Origin", value: originLabel)
                    }
                    Section {
                        LabeledContent("File") {
                            Text(book.fileURL.path(percentEncoded: false))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        LabeledContent("Cover", value: book.coverPath ?? "—")
                    }
                }
                .formStyle(.grouped)
            }
            .padding()
        }
        .navigationTitle(book.title)
        .navigationSubtitle(book.authors.first ?? "Unknown")
        .toolbar {
            if let device = state.device, device.canAccept(book) {
                ToolbarItem(placement: .primaryAction) {
                    if isOnDevice {
                        Label("On \(device.displayName)", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.secondary)
                            .help("This book is already on the connected \(device.displayName).")
                    } else {
                        Button {
                            Task { await state.sendToDevice(book: book) }
                        } label: {
                            Label("Send to \(device.displayName)", systemImage: "ipad.and.iphone")
                        }
                        .help(sendHelpText)
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: book.fileURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .help("Share this book — pick a destination from the system share sheet (e.g. Amazon's Send to Kindle app, AirDrop, Mail).")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { showingEdit = true }
            }
        }
        .sheet(isPresented: $showingEdit) {
            EditBookView(book: book, state: state) { updated in
                Task { await state.updateBook(updated) }
            }
        }
        .fileImporter(
            isPresented: $showingCoverPicker,
            allowedContentTypes: [.image]
        ) { result in
            if case .success(let url) = result {
                Task { await state.setCover(for: book, fromFile: url) }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            coverView

            VStack(alignment: .leading, spacing: 8) {
                Text(book.title)
                    .font(.title)
                    .textSelection(.enabled)
                Text(book.authors.joined(separator: ", "))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let year = book.year {
                    Text(String(year))
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
    }

    private var coverView: some View {
        LocalCoverImage(url: book.coverURL)
            .frame(width: 160, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(radius: 4)
            .contextMenu {
                Button("Replace from File…") { showingCoverPicker = true }
                Button("Paste") { pasteCover() }
                    .disabled(!clipboardHasImage)
                if book.coverPath != nil {
                    Divider()
                    Button("Remove Cover", role: .destructive) {
                        Task { await state.removeCover(for: book) }
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: { isImageFile($0) }) else { return false }
                Task { await state.setCover(for: book, fromFile: url) }
                return true
            }
    }

    private var languageRow: some View {
        LabeledContent("Language", value: book.localeDisplayName)
    }

    private var originLabel: String {
        switch book.origin {
        case .manualImport: "Manual import"
        case .source(let id, _): "Source: \(id)"
        }
    }

    private var clipboardHasImage: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    private var sendHelpText: String {
        guard let device = state.device else { return "Plug in a device to enable USB delivery." }
        return "Copy this book to \(device.displayName). It'll appear on the device after you eject."
    }

    private var isOnDevice: Bool {
        guard let device = state.device else { return false }
        return state.deviceFilenames.contains(device.deviceFilename(for: book))
    }

    private func pasteCover() {
        guard let image = NSImage(pasteboard: NSPasteboard.general) else { return }
        Task { await state.setCover(for: book, image: image) }
    }

    private func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }
}
