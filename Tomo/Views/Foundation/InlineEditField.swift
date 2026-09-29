import SwiftUI

/// Borderless text field that reads as plain text until focused. A subtle
/// background marks it as editable on hover, stronger while focused.
/// Commits on Enter or blur, cancels on Escape.
///
/// It's a `TextField` at rest too, so a single click places the caret and
/// the row keeps the same height and baseline in both states. Keyboard focus
/// is the only editing state, so at most one field is active.
///
/// The caller passes the current value and an `onCommit` closure; the draft
/// mirrors `value` except while focused.
///
/// `completion` enables inline completion: given the draft, return the full
/// completed text (or nil). While typing at the end of the draft, the
/// remainder shows greyed out after it; Tab or → accepts it.
struct InlineEditField: View {
    let value: String
    var placeholder: String = ""
    var font: Font = .system(size: 13)
    var color: Color = .primary
    var alignment: Alignment = .leading
    /// Wrap onto a second line instead of scrolling. Only for values that
    /// are often long (titles, author lists): a wrapping field grows an empty
    /// second line when its text ends exactly at the edge.
    var wraps = false
    var completion: ((String) -> String?)? = nil
    /// Focus the field as soon as it appears (e.g. a row the user just added).
    var focusOnAppear = false
    let onCommit: (String) -> Void

    @State private var draft = ""
    /// True while the last edit grew or shrank the draft at its end — a
    /// proxy for "caret is at the end". Not a `selection:` binding, which
    /// makes the caret flash at the start of the field on click.
    @State private var typingAtEnd = false
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft, axis: wraps ? .vertical : .horizontal)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(color)
            .multilineTextAlignment(alignment.horizontal == .trailing ? .trailing : .leading)
            .lineLimit(wraps ? 2 : 1)
            .focused($focused)
            .overlay(alignment: .topLeading) { completionGhost }
            .onSubmit { focused = false }
            .onExitCommand {
                draft = value
                focused = false
            }
            .onKeyPress(keys: [.tab, .rightArrow]) { _ in
                acceptCompletion() ? .handled : .ignored
            }
            .onKeyPress(keys: [.leftArrow, .upArrow, .downArrow]) { _ in
                typingAtEnd = false
                return .ignored
            }
            .onChange(of: draft) { old, new in
                typingAtEnd = focused && new != old && (new.hasPrefix(old) || old.hasPrefix(new))
            }
            .onAppear { draft = value }
            .task {
                // Deferred past `onAppear` so the field is in the window
                // when focus is requested.
                if focusOnAppear { focused = true }
            }
            .onChange(of: value) { _, newValue in
                if !focused { draft = newValue }
            }
            .onChange(of: focused) { _, isFocused in
                typingAtEnd = false
                if !isFocused { commit() }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(backgroundOpacity))
            )
            .padding(.vertical, -2)
            .padding(.horizontal, -4)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.15), value: hovered)
            .animation(.easeOut(duration: 0.15), value: focused)
    }

    private var backgroundOpacity: Double {
        if focused { return Theme.Surface.pressSoft }
        if hovered { return Theme.Surface.hoverSoft }
        return 0
    }

    private var completedDraft: String? {
        guard focused, typingAtEnd, let completed = completion?(draft),
            completed.count > draft.count
        else { return nil }
        return completed
    }

    /// The draft rendered invisibly (to push the remainder to the caret's
    /// position) followed by the greyed-out remainder.
    @ViewBuilder
    private var completionGhost: some View {
        if let completed = completedDraft {
            let remainder = String(completed.dropFirst(draft.count))
            Text("\(Text(draft).foregroundStyle(.clear))\(Text(remainder).foregroundStyle(.primary.opacity(Theme.Text.placeholder)))")
                .font(font)
                .lineLimit(wraps ? 2 : 1)
                .allowsHitTesting(false)
        }
    }

    private func acceptCompletion() -> Bool {
        guard let completed = completedDraft else { return false }
        draft = completed
        return true
    }

    private func commit() {
        // A wrapping field accepts pasted or Option-Return line breaks.
        // Values are single-line (titles become folder names).
        let singleLine = draft
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        // A rejected edit (empty title, unparseable year) snaps back; an
        // accepted one arrives through `value` once the save lands.
        draft = value
        if singleLine != value {
            onCommit(singleLine)
        }
    }
}

/// Completes `draft` to the candidate that starts with it (case-insensitive),
/// preferring the most-used one. Returns the candidate as stored, so
/// accepting "ursula" yields "Ursula K. Le Guin". Nil for an empty draft or
/// when nothing longer matches.
func prefixCompletion(for draft: String, in counts: [String: Int]) -> String? {
    guard !draft.isEmpty else { return nil }
    let best = counts
        .filter { name, _ in
            name.count > draft.count
                && name.range(of: draft, options: [.caseInsensitive, .anchored]) != nil
        }
        .max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key.localizedStandardCompare(rhs.key) == .orderedDescending
        }
    return best?.key
}

/// Completion for a comma-separated list: completes only the entry after the
/// last comma and skips names already in the list.
func listCompletion(for draft: String, in counts: [String: Int]) -> String? {
    let parts = draft.split(separator: ",", omittingEmptySubsequences: false)
    guard let last = parts.last else { return nil }
    let entry = last.drop { $0 == " " }
    let existing = Set(parts.dropLast().map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    let remaining = counts.filter { !existing.contains($0.key.lowercased()) }
    guard let completed = prefixCompletion(for: String(entry), in: remaining) else { return nil }
    return String(draft.dropLast(entry.count)) + completed
}
