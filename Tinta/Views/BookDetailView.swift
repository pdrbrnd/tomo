import SwiftUI

struct BookDetailView: View {
    let book: Book
    let state: AppState

    private var profile: LanguageProfile? {
        guard let id = book.languageProfileId else { return nil }
        return state.profiles.first { $0.id == id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                Form {
                    Section {
                        languageRow
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
            }
            .padding()
        }
        .navigationTitle(book.title)
        .navigationSubtitle(book.authors.first ?? "Unknown")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            LocalCoverImage(url: book.coverURL)
                .frame(width: 160, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(radius: 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(book.title)
                    .font(.title)
                    .textSelection(.enabled)
                Text(book.authors.joined(separator: ", "))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let year = book.year {
                    Text(String(year))
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var languageRow: some View {
        if let profile, let confidence = book.languageConfidence {
            LabeledContent("Language") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(profile.label)
                    Text("\(profile.id) · \(Int((confidence * 100).rounded()))% confidence")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            LabeledContent("Language", value: book.languageCode)
        }
    }

    private var originLabel: String {
        switch book.origin {
        case .manualImport: "Manual import"
        case .source(let id, _): "Source: \(id)"
        }
    }
}
