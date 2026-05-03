import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var state: AppState
    @State private var showFolderPicker = false

    var body: some View {
        Form {
            LabeledContent("Library folder") {
                if let folder = state.libraryFolder {
                    Text(folder.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Not set")
                        .foregroundStyle(.secondary)
                }
            }

            Button("Choose Folder…") {
                showFolderPicker = true
            }
        }
        .padding()
        .frame(width: 520)
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                state.libraryFolder = url
            }
        }
    }
}
