import Foundation
import UniformTypeIdentifiers
import CoreTransferable

/// Payload for in-app book drags.
///
/// Both source and destination use SwiftUI's Transferable plumbing
/// (`.draggable` / `.dropDestination(for: BookDrag.self)`). The custom UTType
/// is declared in Info.plist (`UTExportedTypeDeclarations`) so Launch
/// Services-backed conformance checks succeed — without that, hover and
/// drop matching fail silently for dynamic UTIs.
///
/// Custom type means external Finder file drops (URL-typed) don't match
/// the in-app drop destinations, so the import overlay only fires for
/// genuinely external drags.
extension UTType {
    nonisolated static let acervoBookDrag = UTType(exportedAs: "com.pdrbrnd.acervo.book-drag")
}

nonisolated struct BookDrag: Codable, Sendable, Transferable {
    let bookIDs: [UUID]

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .acervoBookDrag) { drag in
            try JSONEncoder().encode(drag)
        } importing: { data in
            try JSONDecoder().decode(BookDrag.self, from: data)
        }
    }
}
