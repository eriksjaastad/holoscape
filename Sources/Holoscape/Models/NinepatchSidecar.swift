import Foundation

/// Sidecar file describing 9-slice stretch ranges for a skin image.
///
/// Loaded from `<image>.ninepatch.json` alongside the source PNG. The two
/// ranges define the pixel band that stretches — everything outside those
/// ranges (the corners) renders at 1:1 scale.
///
/// Example for a 64×32 button with 16px corners:
///
///   { "stretchX": [16, 48], "stretchY": [16, 16] }
///
/// The values feed `CALayer.contentsCenter` at render time.
struct NinepatchSidecar: Codable, Equatable, Sendable {
    /// Two-element `[startPixel, endPixel]` range describing the horizontal
    /// stretchable band of the source image.
    var stretchX: [Int]

    /// Two-element `[startPixel, endPixel]` range describing the vertical
    /// stretchable band of the source image.
    var stretchY: [Int]

    /// True when both ranges are two elements and define non-degenerate
    /// (non-zero-width) stretch bands. Zero-width bands (start == end)
    /// produce a zero-area `contentsCenter` rect on CALayer which bypasses
    /// the stretch fallback silently — treated as invalid.
    /// Callers fall back to `.stretch` tile mode when this is false.
    var isValid: Bool {
        guard stretchX.count == 2, stretchY.count == 2 else { return false }
        guard stretchX[0] >= 0, stretchY[0] >= 0 else { return false }
        return stretchX[0] < stretchX[1] && stretchY[0] < stretchY[1]
    }
}
