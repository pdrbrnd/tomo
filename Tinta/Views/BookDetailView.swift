import SwiftUI

struct BookDetailView: View {
    let book: Book

    var body: some View {
        Form {
            Section {
                LabeledContent("Title", value: book.title)
                LabeledContent("Authors", value: book.authors.joined(separator: ", "))
                LabeledContent("Year", value: book.year.map(String.init) ?? "—")
                LabeledContent("Language", value: book.languageCode)
            }

            Section {
                LabeledContent("Date added", value: book.dateAdded.formatted(.dateTime.year().month().day()))
                LabeledContent("Origin", value: originLabel)
            }

            Section {
                LabeledContent("File") {
                    Text(book.fileURL.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                LabeledContent("Cover", value: book.coverPath ?? "—")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(book.title)
        .navigationSubtitle(book.authors.first ?? "Unknown")
    }

    private var originLabel: String {
        switch book.origin {
        case .manualImport: "Manual import"
        case .source(let id, _): "Source: \(id)"
        }
    }
}
