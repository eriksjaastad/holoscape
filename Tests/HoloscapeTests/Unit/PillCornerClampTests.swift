import XCTest
import AppKit
@testable import Holoscape

/// Amplify Task 15.3 — pill-shape corner clamp.
///
/// Requirement 7.5 mandates: when a skin declares `corner: uniform(r)`
/// and `r > height / 2`, the applied `layer.cornerRadius` is clamped
/// to `height / 2`. This produces a pill shape rather than letting
/// the radius exceed the view bounds (which would collapse the button
/// into a circle).
///
/// Tested at the SkinContext level — `applyBorderAndCorner` with the
/// new `clampCornerToHalfHeight` parameter. The behavior is uniform
/// across chrome views; the clamp doesn't belong on a view-specific
/// test.
@MainActor
final class PillCornerClampTests: XCTestCase {

    private func makeSurface(corner: CornerDescriptor) -> SkinContext.ResolvedSurface {
        SkinContext.ResolvedSurface(
            fill: .color(.black),
            border: nil,
            corner: Self.convertCorner(corner),
            padding: NSEdgeInsets(),
            shadow: nil,
            font: nil,
            text: SkinContext.ResolvedText(color: .white, shadow: nil),
            animation: nil,
            states: []
        )
    }

    private static func convertCorner(_ corner: CornerDescriptor) -> SkinContext.ResolvedCorner {
        switch corner {
        case .uniform(let r): return .uniform(CGFloat(r))
        case .asymmetric(let tl, let tr, let br, let bl):
            return .asymmetric(
                topLeft: CGFloat(tl),
                topRight: CGFloat(tr),
                bottomRight: CGFloat(br),
                bottomLeft: CGFloat(bl)
            )
        }
    }

    private func makeContext() -> SkinContext {
        SkinContext(surfaces: [:], reactive: ReactiveUniformSnapshot())
    }

    // MARK: - Clamp behavior

    func testUniformRadiusClampedToHalfHeight() {
        // A skin declaring corner: 9999 on a 30pt-tall tab must cap
        // at 15pt. Without the clamp, cornerRadius would exceed the
        // view bounds and produce a visual degenerate case.
        let layer = CALayer()
        let ctx = makeContext()
        let surface = makeSurface(corner: .uniform(9999))
        ctx.applyBorderAndCorner(
            to: layer,
            from: surface,
            clampCornerToHalfHeight: 30
        )
        XCTAssertEqual(layer.cornerRadius, 15,
                       "cornerRadius must clamp to height / 2 for pill-shape tabs (Req 7.5)")
    }

    func testUniformRadiusBelowHalfHeightPassesThrough() {
        // A skin declaring a reasonable radius (6 < 15) must NOT be
        // clamped — otherwise every non-pill skin would be capped
        // regardless of author intent.
        let layer = CALayer()
        let ctx = makeContext()
        let surface = makeSurface(corner: .uniform(6))
        ctx.applyBorderAndCorner(
            to: layer,
            from: surface,
            clampCornerToHalfHeight: 30
        )
        XCTAssertEqual(layer.cornerRadius, 6,
                       "Reasonable radius must pass through unchanged")
    }

    func testClampAtExactHalfHeightIsIdentity() {
        // Boundary: radius == halfHeight must produce radius == halfHeight
        // (not clipped to halfHeight - epsilon).
        let layer = CALayer()
        let ctx = makeContext()
        let surface = makeSurface(corner: .uniform(15))
        ctx.applyBorderAndCorner(
            to: layer,
            from: surface,
            clampCornerToHalfHeight: 30
        )
        XCTAssertEqual(layer.cornerRadius, 15)
    }

    func testNoClampWhenClampHeightNil() {
        // The clamp parameter is optional. Callers that don't pass it
        // (sidebar rows, launcher container) must see the radius
        // applied verbatim — clamp behavior is opt-in.
        let layer = CALayer()
        let ctx = makeContext()
        let surface = makeSurface(corner: .uniform(9999))
        ctx.applyBorderAndCorner(to: layer, from: surface)
        XCTAssertEqual(layer.cornerRadius, 9999,
                       "Without clampCornerToHalfHeight, radius applies as-declared")
    }

    // MARK: - Shadow helper independence

    /// Task 15.1 extracted `applyShadow` as a standalone helper. It
    /// can be called without applying border/corner. This test pins
    /// the split: applyShadow on a surface without border/corner
    /// touches shadow properties only.
    func testApplyShadowIsIndependentOfBorderAndCorner() {
        let layer = CALayer()
        layer.borderWidth = 5
        layer.cornerRadius = 10
        let ctx = makeContext()
        let surface = SkinContext.ResolvedSurface(
            fill: .color(.black),
            border: nil,
            corner: .uniform(0),
            padding: NSEdgeInsets(),
            shadow: SkinContext.ResolvedShadow(
                color: .red, opacity: 0.5, blur: 3, offset: CGSize(width: 1, height: 2)
            ),
            font: nil,
            text: SkinContext.ResolvedText(color: .white, shadow: nil),
            animation: nil, states: []
        )
        ctx.applyShadow(to: layer, from: surface)
        XCTAssertEqual(layer.shadowOpacity, 0.5)
        XCTAssertEqual(layer.shadowRadius, 3)
        XCTAssertEqual(layer.shadowOffset, CGSize(width: 1, height: 2))
        // Border + corner from before the call must be untouched.
        XCTAssertEqual(layer.borderWidth, 5,
                       "applyShadow must not touch borderWidth")
        XCTAssertEqual(layer.cornerRadius, 10,
                       "applyShadow must not touch cornerRadius")
    }

    func testNilShadowZerosOpacity() {
        // Previously-applied shadow must be cleared when a skin
        // switch drops the shadow. Opacity = 0 is the documented way.
        let layer = CALayer()
        layer.shadowOpacity = 0.8
        let ctx = makeContext()
        let surface = makeSurface(corner: .uniform(0))  // shadow: nil implicit
        ctx.applyShadow(to: layer, from: surface)
        XCTAssertEqual(layer.shadowOpacity, 0,
                       "Nil shadow must zero opacity so a previous skin's shadow doesn't persist")
    }
}
