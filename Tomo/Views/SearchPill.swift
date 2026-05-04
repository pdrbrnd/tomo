import SwiftUI

/// Search pill that grows on focus from a compact resting state.
///
/// SwiftUI's `.animation(_, value:)` applied to a `.frame(width:)` driven by a
/// computed property doesn't reliably animate when the source is `@FocusState`.
/// The fix: keep the width in `@State`, drive its updates with explicit
/// `withAnimation` blocks via `onChange`.
struct SearchPill<Trailing: View>: View {
    @Binding var text: String
    var placeholder: String = "Search"
    @ViewBuilder var trailing: () -> Trailing
    @FocusState private var focused: Bool

    @State private var pillWidth: CGFloat = SearchPill.minCollapsedWidth

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var minCollapsedWidth: CGFloat { 132 }
    private static var minExpandedWidth: CGFloat { 320 }
    private static var maxWidth: CGFloat { 440 }
    private static var trailingSlot: CGFloat { 22 }

    /// Approximate non-text chrome inside the pill: outer h-padding (13×2),
    /// search icon (13) + icon-to-text spacing (8), text-to-trailing spacing (4),
    /// trailing slot (22), and a small visual buffer so descenders / pixel-
    /// rounding don't clip.
    private static var chromeWidth: CGFloat { 13 + 13 + 13 + 8 + 4 + 22 + 6 }

    var body: some View {
        HStack(spacing: 8) {
            Icon(symbol: "magnifyingglass", weight: .regular, size: 13)
                .foregroundStyle(.primary.opacity(Theme.Text.secondary))

            // Width-flexible cluster — always mounted so focus binds correctly.
            HStack(spacing: 4) {
                TextField("", text: $text, prompt: prompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.primary.opacity(Theme.Text.primary))
                    .focused($focused)
                    .frame(maxWidth: .infinity, alignment: .leading)

                trailing()
                    .frame(width: Self.trailingSlot)
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
        .onChange(of: placeholder) { _, _ in animateWidth() }
        .onAppear { pillWidth = targetWidth() }
    }

    /// Width that fits the placeholder string. When the placeholder is the
    /// default ("Search"), this falls under `minCollapsedWidth`, so we pin
    /// to the minimum. Long placeholders (e.g. "Search Some Collection")
    /// grow the pill so the text isn't clipped at rest.
    private var naturalCollapsedWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textWidth = (placeholder as NSString).size(withAttributes: attrs).width
        let candidate = ceil(textWidth) + Self.chromeWidth
        return min(Self.maxWidth, max(Self.minCollapsedWidth, candidate))
    }

    private func targetWidth() -> CGFloat {
        if focused || !text.isEmpty {
            // Focused: keep at least the standard expanded size, but never
            // shrink below the natural placeholder width — avoids a jarring
            // shrink-on-focus when the placeholder is long.
            return min(Self.maxWidth, max(Self.minExpandedWidth, naturalCollapsedWidth))
        }
        return naturalCollapsedWidth
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
        Text(placeholder).foregroundStyle(.primary.opacity(Theme.Text.placeholder))
    }
}

extension SearchPill where Trailing == EmptyView {
    init(text: Binding<String>, placeholder: String = "Search") {
        self.init(text: text, placeholder: placeholder, trailing: { EmptyView() })
    }
}
