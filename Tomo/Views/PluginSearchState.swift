import Foundation

/// Per-plugin search state. The library section is synchronous; only sources
/// need a lifecycle, so this lives in the view layer and isn't mirrored into
/// any persisted shape.
///
/// Transitions:
///  - kickoff:        nothing → `.loading`
///  - plugin returns: `.loading` → `.loaded(_)`
///  - plugin throws:  `.loading` → `.failed(_)`
///  - search cleared / plugin disabled: removed from the dict entirely
///
/// `Equatable` so SwiftUI can diff state changes without manual signals.
enum PluginSearchState: Equatable {
    case loading
    case loaded([PluginResult])
    case failed(String)

    var results: [PluginResult] {
        if case .loaded(let r) = self { return r }
        return []
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var failureMessage: String? {
        if case .failed(let m) = self { return m }
        return nil
    }
}
