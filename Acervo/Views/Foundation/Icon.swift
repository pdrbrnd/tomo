import SwiftUI
import PhosphorSwift

/// Thin wrapper around Phosphor icons.
///
/// Phosphor's asset catalog doesn't set `preserves-vector-representation`, so
/// Xcode rasterizes the SVGs at intrinsic 256pt size at build. Displaying at
/// small sizes (12-14pt) means a heavy downscale, which produces a soft /
/// pixelated edge with the default interpolation. `.interpolation(.high)`
/// nudges the resampler to a smoother kernel and reads cleaner at small
/// sizes — close enough to crisp without patching the dependency.
struct Icon: View {
    let symbol: Ph
    var weight: Ph.IconWeight = .regular
    var size: CGFloat = 14

    var body: some View {
        symbol.weight(weight)
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}
