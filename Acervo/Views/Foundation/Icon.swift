import SwiftUI

/// Thin wrapper around SF Symbols.
///
/// Centralises the size + weight treatment so every icon in the app stays
/// visually consistent. SF Symbols are vectors at every render, so there's
/// no rasterisation softness at small sizes — that's the reason this
/// replaced the earlier Phosphor-based wrapper.
struct Icon: View {
    let symbol: String
    var weight: Font.Weight = .regular
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: weight))
            .frame(width: size, height: size)
    }
}
