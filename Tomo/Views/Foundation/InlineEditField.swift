import SwiftUI

/// Hover-pencil text field — display mode shows the value with a pencil
/// affordance on hover; click to enter edit mode. Edit mode commits on
/// Enter or blur, cancels on Escape.
///
/// Stateless from the caller's perspective: caller passes the current value
/// and an `onCommit` closure; the field manages its own draft and edit
/// state, but never holds a snapshot of the value across re-renders.
struct InlineEditField: View {
    let value: String
    var placeholder: String = ""
    var font: Font = .system(size: 13)
    var color: Color = .primary
    var alignment: Alignment = .leading
    let onCommit: (String) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        if isEditing { editingView } else { displayView }
    }

    private var displayView: some View {
        HStack(spacing: 6) {
            Text(displayText)
                .font(font)
                .foregroundStyle(displayColor)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: alignment)

            if hovered {
                Icon(symbol: "pencil", weight: .regular, size: 11)
                    .foregroundStyle(.primary.opacity(0.42))
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { begin() }
    }

    private var editingView: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(color)
            .focused($focused)
            .onSubmit { commit() }
            .onAppear {
                draft = value
                focused = true
            }
            .onChange(of: focused) { _, focused in
                // Blur commits — same as Enter. Esc is handled below.
                if !focused, isEditing { commit() }
            }
            .onExitCommand { cancel() }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
            .padding(.vertical, -2)
            .padding(.horizontal, -4)
    }

    private var displayText: String {
        value.isEmpty ? placeholder : value
    }

    private var displayColor: Color {
        value.isEmpty ? Color.primary.opacity(0.4) : color
    }

    private func begin() {
        draft = value
        isEditing = true
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
        if trimmed != value {
            onCommit(trimmed)
        }
    }

    private func cancel() {
        draft = value
        isEditing = false
    }
}
