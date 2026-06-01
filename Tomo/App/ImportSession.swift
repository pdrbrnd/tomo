import Foundation

/// Live state of one batch-import run, observed by `ImportProgressSheet`.
/// Owned by `AppState.importSession`; mutated on the main actor as the
/// orchestrator processes files. The index isn't touched until the whole batch
/// finishes (one bulk `addBooks`), so a row being `.imported` means the file is
/// on disk with its sidecar written, not yet queryable.
@Observable
final class ImportSession: Identifiable {
    enum RowStatus: Equatable {
        case pending
        case importing
        case imported
        /// Exact on-disk identity already present — terminal, no action.
        case alreadyInLibrary
        /// Matches an existing book by title+author but at a different path;
        /// `matchedLabel` explains the match. Importable as a separate book.
        case possibleDuplicate(matchedLabel: String)
        case failed(String)

        var isDone: Bool {
            switch self {
            case .pending, .importing: false
            case .imported, .alreadyInLibrary, .possibleDuplicate, .failed: true
            }
        }
    }

    struct Row: Identifiable {
        let id = UUID()
        let url: URL
        var status: RowStatus = .pending

        var filename: String { url.lastPathComponent }
    }

    let id = UUID()
    var rows: [Row]
    /// True while the batch is still processing; false once every row settled
    /// (or the run was cancelled).
    var isRunning: Bool = true

    init(urls: [URL]) {
        rows = urls.map { Row(url: $0) }
    }

    // MARK: - Derived counts for the grouped UI

    var total: Int { rows.count }
    var processedCount: Int { rows.filter { $0.status.isDone }.count }
    var importedCount: Int { rows.filter { $0.status == .imported }.count }
    var alreadyInLibrary: [Row] { rows.filter { $0.status == .alreadyInLibrary } }
    var possibleDuplicates: [Row] {
        rows.filter { if case .possibleDuplicate = $0.status { return true } else { return false } }
    }
    var failures: [Row] {
        rows.filter { if case .failed = $0.status { return true } else { return false } }
    }
    /// Fraction settled, 0...1. Drives the header progress bar.
    var progress: Double {
        total == 0 ? 1 : Double(processedCount) / Double(total)
    }
}
