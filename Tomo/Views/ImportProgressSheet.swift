import AppKit
import SwiftUI

/// Progress + outcome panel for a batch import. Shows live progress while
/// running, then a grouped summary: a collapsed "imported" count, plus
/// per-row Skipped (duplicate, with Import anyway) and Failed (with Retry /
/// Reveal in Finder) groups. Built on the `DeviceContentsSheet` layout idiom
/// (header → rule → scroll → bottom bar) and the shared Theme vocabulary.
struct ImportProgressSheet: View {
    let session: ImportSession
    let state: AppState

    @State private var alreadyInLibraryExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            insetRule
            content
        }
        .frame(width: 560, height: 520)
        .background(Theme.canvas)
        .overlay(alignment: .bottom) { bottomBar }
        .presentationBackground(Theme.canvas)
        .animation(.spring(duration: 0.34, bounce: 0.18), value: session.processedCount)
        .animation(.easeOut(duration: 0.2), value: session.isRunning)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Icon(symbol: session.isRunning ? "square.and.arrow.down" : "checkmark.circle", size: 16)
                    .foregroundStyle(.primary.opacity(Theme.Text.muted))
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.isRunning ? "Importing books" : "Import complete")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(session.processedCount) of \(session.total)")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(Theme.Text.secondary))
                        .contentTransition(.numericText())
                }
                Spacer()
            }
            ProgressBar(fraction: session.progress)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.md)
        .background(Theme.canvas)
    }

    private var insetRule: some View {
        Rectangle()
            .fill(.primary.opacity(0.10))
            .frame(height: 0.5)
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if session.importedCount > 0 {
                    summaryLine(
                        symbol: "checkmark.circle.fill",
                        tint: .green,
                        text: "\(session.importedCount) imported")
                }

                let alreadyInLibrary = session.alreadyInLibrary
                if !alreadyInLibrary.isEmpty {
                    expandableSummary(
                        symbol: "books.vertical.fill",
                        text: "\(alreadyInLibrary.count) already in library",
                        isExpanded: $alreadyInLibraryExpanded,
                        rows: alreadyInLibrary)
                }

                let dupes = session.possibleDuplicates
                if !dupes.isEmpty {
                    group(title: "Possible duplicates", count: dupes.count) {
                        ForEach(dupes) { row in
                            OutcomeRow(filename: row.filename, detail: matchDetail(row.status)) {
                                Button("Keep Both") { state.retryImportRow(row.id) }
                                    .buttonStyle(PillButtonStyle())
                            }
                        }
                    }
                }

                let failures = session.failures
                if !failures.isEmpty {
                    group(title: "Failed", count: failures.count) {
                        ForEach(failures) { row in
                            OutcomeRow(filename: row.filename, detail: failureMessage(row.status)) {
                                Button("Retry") { state.retryImportRow(row.id) }
                                    .buttonStyle(PillButtonStyle())
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([row.url])
                                } label: {
                                    Icon(symbol: "magnifyingglass", size: 12)
                                }
                                .buttonStyle(PillButtonStyle())
                            }
                        }
                    }
                }

                if session.isRunning {
                    let remaining = session.total - session.processedCount
                    if remaining > 0 {
                        summaryLine(
                            symbol: "arrow.triangle.2.circlepath",
                            tint: .secondary,
                            text: "\(remaining) remaining")
                    }
                }
            }
            .padding(Theme.Spacing.lg)
            .padding(.bottom, 64)  // clear the bottom bar
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func failureMessage(_ status: ImportSession.RowStatus) -> String {
        if case .failed(let message) = status { return message }
        return ""
    }

    private func matchDetail(_ status: ImportSession.RowStatus) -> String {
        if case .possibleDuplicate(let label) = status { return label }
        return ""
    }

    // MARK: - Building blocks

    private func summaryLine(symbol: String, tint: Color, text: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Icon(symbol: symbol, size: 13)
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .contentTransition(.numericText())
            Spacer()
        }
    }

    /// A count summary that expands into its rows on click — collapsed by
    /// default so a big re-drop stays quiet, but the user can still see which
    /// files were flagged. Rows are informational (no actions).
    private func expandableSummary(
        symbol: String,
        text: String,
        isExpanded: Binding<Bool>,
        rows: [ImportSession.Row]
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Icon(symbol: symbol, size: 13)
                        .foregroundStyle(.secondary)
                    Text(text)
                        .font(.system(size: 13, weight: .medium))
                        .contentTransition(.numericText())
                    Spacer()
                    Icon(symbol: "chevron.right", size: 11)
                        .foregroundStyle(.primary.opacity(Theme.Text.tertiary))
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                VStack(spacing: 2) {
                    ForEach(rows) { row in
                        OutcomeRow(filename: row.filename, detail: "") { EmptyView() }
                    }
                }
                // Fade in place; the surrounding layout animates the height so
                // the rows reveal downward like an accordion. No directional
                // move (that slides the block in from above the header).
                .transition(.opacity)
            }
        }
        .clipped()
    }

    private func group<Content: View>(
        title: String, count: Int, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(Theme.Text.secondary))
                Text("\(count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(Theme.Text.tertiary))
            }
            VStack(spacing: 2) { content() }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            Spacer()
            if session.isRunning {
                Button("Cancel") { state.cancelImport() }
                    .buttonStyle(PillButtonStyle())
            } else {
                Button("Done") { state.dismissImportSession() }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.lg)
        .background(
            LinearGradient(
                colors: [Theme.canvas.opacity(0), Theme.canvas],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
        )
    }
}

// MARK: - Outcome row

private struct OutcomeRow<Actions: View>: View {
    let filename: String
    let detail: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(filename)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(Theme.Text.secondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Spacing.md)
            actions()
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.menuItem, style: .continuous)
                .fill(.primary.opacity(Theme.Surface.hover))
        )
    }
}

// MARK: - Progress bar

private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule()
                    .fill(.primary.opacity(0.55))
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, fraction))))
            }
        }
        .frame(height: 4)
    }
}
