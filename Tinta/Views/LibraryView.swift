import SwiftUI
import UniformTypeIdentifiers
import os

private nonisolated let logger = Logger(subsystem: "com.pdrbrnd.tinta", category: "metadata")

struct LibraryView: View {
    let state: AppState
    @State private var showEPUBPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tinta")
                .font(.largeTitle)

            if let folder = state.libraryFolder {
                Text("Library: \(folder.path(percentEncoded: false))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("No library folder set. Open Settings (⌘,) to choose one.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 300, alignment: .topLeading)
        .toolbar {
            Button("Debug: Read EPUB") { showEPUBPicker = true }
        }
        .fileImporter(
            isPresented: $showEPUBPicker,
            allowedContentTypes: [UTType(filenameExtension: "epub") ?? .data]
        ) { result in
            if case .success(let url) = result {
                Task.detached {
                    do {
                        let metadata = try EPUBMetadata.read(from: url)
                        logger.info("title: \(metadata.title, privacy: .public)")
                        logger.info("authors: \(metadata.authors, privacy: .public)")
                        logger.info("language: \(metadata.language ?? "?", privacy: .public)")
                        logger.info("year: \(metadata.year.map(String.init) ?? "?", privacy: .public)")
                        if let cover = metadata.coverImage {
                            logger.info("cover: \(cover.data.count) bytes (\(cover.pathExtension, privacy: .public))")
                        } else {
                            logger.info("cover: none")
                        }
                    } catch {
                        logger.error("EPUB read failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }
}
