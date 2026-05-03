import SwiftUI
import AppKit
import PhosphorSwift

/// Inspector that presents a single book and exposes actions as callbacks.
///
/// Doesn't reach into `AppState` directly — the parent owns the state and
/// passes in already-resolved data + actions. Keeps the layered architecture
/// (Models / Core / Views) clean: inspector renders and calls.
struct BookInspector: View {
    let book: Book?
    let device: DeviceContext?
    /// Set when the parent has more than one book selected. The inspector
    /// can't render a single book's metadata, so it shows a count placeholder.
    var multiSelectionCount: Int? = nil

    let onClose: () -> Void
    let onEdit: () -> Void
    let onShowInFinder: () -> Void
    let onSendToDevice: () -> Void
    let onRequestDelete: () -> Void

    /// Pre-resolved device context: lets the view branch on send-to-device
    /// without knowing about `BookDevice` or `AppState`.
    struct DeviceContext {
        let displayName: String
        let isOnDevice: Bool
        let canSend: Bool
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.panel

            if let book {
                content(for: book)
            } else if let count = multiSelectionCount {
                multiState(count: count)
            } else {
                emptyState
            }

            closeButton
                .padding(.top, Theme.Spacing.sm)
                .padding(.leading, Theme.Spacing.sm)
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("Select a book")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary.opacity(0.42))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func multiState(count: Int) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            Spacer()
            Text("\(count) books selected")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.85))
            Text("Select a single book to see details.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.primary.opacity(0.45))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            ZStack {
                // Surface elevation (slightly brighter than panel) so the
                // close button is visible against the canvas-colored panel.
                Circle().fill(Theme.surface)
                Circle().stroke(Theme.hairline, lineWidth: 0.5)
                Icon(symbol: .x, weight: .bold, size: 11)
                    .foregroundStyle(.primary.opacity(0.62))
            }
            .frame(width: 32, height: 32)
            .softShadow(elevated: false)
        }
        .buttonStyle(.plain)
        .help("Close inspector (⌘I)")
    }

    @ViewBuilder
    private func content(for book: Book) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(for: book)
                    .padding(.top, 56)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.xl + Theme.Spacing.xs)

                metadataSection(for: book)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.xl)

                actions(for: book)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.bottom, Theme.Spacing.xxl)
            }
        }
    }

    private func header(for book: Book) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            LocalCoverImage(url: book.coverURL, fallbackTitle: book.title)
                .frame(width: 132, height: 198)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover + 2, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.cover + 2, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 0.5)
                )
                .softShadow(elevated: false)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(book.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)

                Text(book.authors.joined(separator: ", "))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary.opacity(0.62))
                    .textSelection(.enabled)

                if let year = book.year {
                    Text(String(year))
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.42))
                        .padding(.top, 2)
                }
            }
        }
    }

    private func metadataSection(for book: Book) -> some View {
        VStack(spacing: 0) {
            metaRow("Language", value: book.localeDisplayName)
            metaRow("Format", value: book.fileURL.pathExtension.uppercased())
            metaRow("Added", value: book.dateAdded.formatted(.dateTime.year().month(.abbreviated).day()))
            metaRow("Origin", value: originLabel(for: book))
            metaRow("File", value: book.fileURL.lastPathComponent, monospaced: true)
        }
    }

    private func metaRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.primary.opacity(0.42))
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .regular, design: monospaced ? .monospaced : .default))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Theme.Spacing.sm)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func actions(for book: Book) -> some View {
        VStack(spacing: 0) {
            if let device, device.canSend {
                Button(action: onSendToDevice) {
                    actionLabel(
                        icon: device.isOnDevice ? .check : .deviceTablet,
                        title: device.isOnDevice ? "On \(device.displayName)" : "Send to \(device.displayName)"
                    )
                }
                .disabled(device.isOnDevice)
                .opacity(device.isOnDevice ? 0.5 : 1.0)
            }
            Button(action: onEdit) {
                actionLabel(icon: .pencilSimple, title: "Edit…")
            }
            Button(action: onShowInFinder) {
                actionLabel(icon: .folderOpen, title: "Show in Finder")
            }
            Button(role: .destructive, action: onRequestDelete) {
                actionLabel(icon: .trash, title: "Move to Trash…")
            }
        }
        .buttonStyle(MenuRowStyle())
    }

    private func actionLabel(icon: Ph, title: String) -> some View {
        HStack(spacing: 9) {
            Icon(symbol: icon, weight: .regular, size: 13)
                .frame(width: 14)
            Text(title)
        }
    }

    private func originLabel(for book: Book) -> String {
        switch book.origin {
        case .manualImport: "Manual import"
        case .source(let id, _): "Source: \(id)"
        }
    }
}
