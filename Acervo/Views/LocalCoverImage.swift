import SwiftUI
import AppKit

struct LocalCoverImage: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                placeholder
            }
        }
        .task(id: url) { await load() }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)
            Image(systemName: "book.closed")
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        guard let url else { image = nil; return }
        image = await Task.detached { NSImage(contentsOf: url) }.value
    }
}
