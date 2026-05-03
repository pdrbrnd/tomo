import SwiftUI

struct EditBookView: View {
    @Environment(\.dismiss) private var dismiss

    let original: Book
    let state: AppState
    let onSave: (Book) -> Void

    @State private var title: String
    @State private var authorsText: String
    @State private var yearText: String
    @State private var locale: String
    @State private var classifying = false
    @State private var lastClassification: Classification?

    init(book: Book, state: AppState, onSave: @escaping (Book) -> Void) {
        self.original = book
        self.state = state
        self.onSave = onSave
        _title = State(initialValue: book.title)
        _authorsText = State(initialValue: book.authors.joined(separator: ", "))
        _yearText = State(initialValue: book.year.map(String.init) ?? "")
        _locale = State(initialValue: book.locale)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Bibliographic") {
                    TextField("Title", text: $title)
                    TextField("Authors", text: $authorsText)
                        .help("Multiple authors separated by commas")
                    TextField("Year", text: $yearText)
                }

                Section("Language") {
                    Picker("Locale", selection: $locale) {
                        Text(Locale.current.localizedString(forIdentifier: "und") ?? "Unknown").tag("und")
                        ForEach(state.profiles) { profile in
                            Text(profile.displayName).tag(profile.id)
                        }
                        // Keep the current value selectable when it isn't a known
                        // profile (e.g. an EPUB that declared just "pt"). Avoids
                        // silently losing a value the user didn't touch.
                        if shouldShowExtraOption {
                            let baseName = Locale.current.localizedString(forIdentifier: original.locale) ?? original.locale
                            Text("\(baseName) (declared)").tag(original.locale)
                        }
                    }
                    .onChange(of: locale) { _, newValue in
                        // Manual change away from the classifier's pick clears the
                        // transient confidence read-out — it no longer reflects
                        // what's selected.
                        if let last = lastClassification, last.profileId != newValue {
                            lastClassification = nil
                        }
                    }

                    HStack {
                        if let last = lastClassification {
                            Text("Classifier: \(Int((last.confidence * 100).rounded()))% confidence")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { await reclassify() }
                        } label: {
                            if classifying {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Re-classify from text", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(classifying)
                        .help("Run the classifier on this book's text. Updates the picker; not saved until you click Save.")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 460)
    }

    private var shouldShowExtraOption: Bool {
        original.locale != "und" &&
        !state.profiles.contains(where: { $0.id == original.locale })
    }

    private func save() {
        var updated = original
        updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.authors = authorsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        updated.year = Int(yearText.trimmingCharacters(in: .whitespacesAndNewlines))
        updated.locale = locale
        onSave(updated)
    }

    private func reclassify() async {
        classifying = true
        defer { classifying = false }

        let url = original.fileURL
        let availableProfiles = state.profiles
        let result = await Task.detached {
            Classifier.classifyEPUB(at: url, profiles: availableProfiles)
        }.value

        lastClassification = result
        locale = result?.profileId ?? "und"
    }
}
