import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Payload for in-app book drags.
///
/// In-app only: carries the selected book IDs through SwiftUI's Transferable
/// system to the device tile. External destinations (Finder, Mail, etc.)
/// don't recognize this type and reject the drop — drag-to-Finder export is
/// deferred (see `docs/drag_out_export.md`).
///
/// The custom UTI is declared in Info.plist (`UTExportedTypeDeclarations`).
/// Without that declaration, `UTType(exportedAs:)` returns a runtime-only
/// "dynamic" UTI whose conformance checks fail silently — and SwiftUI's
/// drop-destination matching uses those checks.
extension UTType {
  nonisolated static let tomoBookDrag = UTType(exportedAs: "com.pdrbrnd.tomo.book-drag")
}

nonisolated struct BookDrag: Codable, Sendable, Transferable {
  let bookIDs: [UUID]

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(contentType: .tomoBookDrag) { drag in
      try JSONEncoder().encode(drag)
    } importing: { data in
      try JSONDecoder().decode(BookDrag.self, from: data)
    }
  }
}
