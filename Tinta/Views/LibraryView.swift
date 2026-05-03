import SwiftUI

struct LibraryView: View {
    let state: AppState

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
    }
}
