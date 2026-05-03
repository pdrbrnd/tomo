import SwiftUI
import PhosphorSwift

/// Search pill that grows on focus from a compact resting state.
///
/// SwiftUI's `.animation(_, value:)` applied to a `.frame(width:)` driven by a
/// computed property doesn't reliably animate when the source is `@FocusState`.
/// The fix: keep the width in `@State`, drive its updates with explicit
/// `withAnimation` blocks via `onChange`.
struct SearchPill: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    @State private var pillWidth: CGFloat = SearchPill.collapsedWidth

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let collapsedWidth: CGFloat = 132
    private static let expandedWidth: CGFloat = 320
    private static let clearButtonSlot: CGFloat = 18

    var body: some View {
        HStack(spacing: 8) {
            Icon(symbol: .magnifyingGlass, weight: .regular, size: 13)
                .foregroundStyle(.primary.opacity(0.55))

            // Width-flexible cluster — always mounted so focus binds correctly.
            HStack(spacing: 4) {
                TextField("", text: $text, prompt: prompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.primary.opacity(0.92))
                    .focused($focused)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    text = ""
                } label: {
                    Icon(symbol: .xCircle, weight: .fill, size: 13)
                        .foregroundStyle(.primary.opacity(0.42))
                }
                .buttonStyle(.plain)
                .frame(width: Self.clearButtonSlot)
                .opacity(text.isEmpty ? 0 : 1)
                .allowsHitTesting(!text.isEmpty)
            }
        }
        .padding(.horizontal, 13)
        .frame(width: pillWidth, height: 32)
        .background(
            ZStack {
                Capsule(style: .continuous)
                    .fill(Theme.surface)
                Capsule(style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 0.5)
            }
        )
        .softShadow(elevated: focused)
        .contentShape(Capsule(style: .continuous))
        .onTapGesture { focused = true }
        .onChange(of: focused) { _, _ in animateWidth() }
        .onChange(of: text.isEmpty) { _, _ in animateWidth() }
        .onAppear { pillWidth = targetWidth() }
    }

    private func targetWidth() -> CGFloat {
        let expanded = focused || !text.isEmpty
        return expanded ? Self.expandedWidth : Self.collapsedWidth
    }

    private func animateWidth() {
        let new = targetWidth()
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.12)) { pillWidth = new }
        } else {
            // Snappy: short duration with a hint of bounce — fast and alive.
            withAnimation(.smooth(duration: 0.18, extraBounce: 0.08)) { pillWidth = new }
        }
    }

    private var prompt: Text {
        Text("Search").foregroundStyle(.primary.opacity(0.42))
    }
}
