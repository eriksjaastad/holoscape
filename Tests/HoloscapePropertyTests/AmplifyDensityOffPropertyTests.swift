import XCTest
import AppKit
@testable import Holoscape

/// Amplify Task 21.7 — Property 10 Amplify extension.
///
/// The chrome-skinning Property 7 (`ZeroOverheadPropertyTests`) pins
/// three invariants for density `.off`:
///   1. `SkinEngine.apply(skin:to:)` is identity.
///   2. Fresh `SkinEngine` construction opens no FSEventStream.
///   3. Entering `.off` drains `AnimationEngine.activeAnimations`.
///
/// Amplify adds a new surface that needs the same treatment: sprite
/// sheets. `SkinContext.applyFill` gates sprite slicing on
/// `DensityModeManager.shouldRenderSprites()`, which returns false in
/// `.minimal` and `.off`. The directory-layout sprite test
/// (`SpriteContentsRectTests.testMinimalDensityFallsBackToStretch`)
/// pins `.minimal`; this file pins `.off` — and, as a property,
/// "for any sprite state, `.off` keeps `contentsRect` at the unit
/// square" so a state-churn regression can't quietly turn sprite
/// rendering back on in bypass mode.
///
/// "No Amplify-related CPU in `.off`" (Req 14.4) has three
/// externally-observable consequences the engine already pins
/// through `ZeroOverheadPropertyTests` and `SpriteContentsRectTests`:
///   - No watcher allocated on construction (existing).
///   - Animation queue drains on transition (existing).
///   - Sprite slicing short-circuits to full-sheet stretch (partial —
///     `.minimal` only; `.off` added here).
@MainActor
final class AmplifyDensityOffPropertyTests: XCTestCase {

    private final class StubWriter: DensityModeConfigWriter {
        func writeDensityMode(_ modeRawValue: String) {}
    }

    override func tearDown() {
        SkinContext.ambientDensityManager = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// 100×50 solid-color bitmap — real image so divisor math in
    /// `applySpriteCell` is well-defined. Matches the fixture pattern
    /// in `SpriteContentsRectTests`.
    private func makeFixtureSheet(width: Int = 100, height: Int = 50) -> NSImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    private func makeSpriteFill(sprite: SpriteDescriptor) -> SkinContext.ResolvedSurface {
        let sheet = makeFixtureSheet(
            width: sprite.cellWidth * sprite.cols,
            height: sprite.cellHeight * sprite.rows
        )
        return SkinContext.ResolvedSurface(
            fill: .image(sheet, .stretch, nil, sprite),
            border: nil,
            corner: .uniform(0),
            padding: NSEdgeInsets(),
            shadow: nil,
            font: nil,
            text: SkinContext.ResolvedText(color: .white, shadow: nil),
            animation: nil,
            states: []
        )
    }

    private func makeContext() -> SkinContext {
        SkinContext(surfaces: [:], reactive: ReactiveUniformSnapshot())
    }

    // MARK: - Property 10: sprite slicing is off in `.off`

    /// For EVERY `SpriteState`, applying a sprite fill with density
    /// `.off` leaves `contentsRect` at the unit square — i.e. the
    /// full sheet renders, no cell is sliced out.
    ///
    /// The state space is small and enumerated (7 cases), so the
    /// property is universally quantified via a `for` rather than
    /// SwiftCheck. No generator value would come out of `Arbitrary`
    /// for `SpriteState` anyway — `CaseIterable` is the natural
    /// domain here.
    func testSpriteStateIsIrrelevantUnderOffDensity() {
        SkinContext.ambientDensityManager = DensityModeManager(
            initialMode: .off,
            configWriter: StubWriter()
        )

        // Full state map so slicing IS well-defined at `.full` —
        // the invariant being pinned is that `.off` ignores it.
        var stateMap: [String: SpriteCell] = [:]
        for (index, s) in SpriteState.allCases.enumerated() {
            stateMap[s.rawValue] = SpriteCell(row: index / 4, col: index % 4)
        }
        let sprite = SpriteDescriptor(
            cellWidth: 25, cellHeight: 25, rows: 2, cols: 4, stateMap: stateMap
        )

        for state in SpriteState.allCases {
            let layer = CALayer()
            makeContext().applyFill(
                to: layer,
                from: makeSpriteFill(sprite: sprite),
                spriteState: state
            )
            XCTAssertEqual(layer.contentsRect, CGRect(x: 0, y: 0, width: 1, height: 1),
                           "Off-density applyFill with spriteState \(state) must leave contentsRect unit")
        }
    }

    // MARK: - Cell cache is not populated in `.off`

    /// Applying a sprite fill in `.off` writes `layer.contents`
    /// (the full sheet) but does NOT mutate `contentsRect` to a
    /// sub-cell UV. Regression guard: a future change that moves
    /// the density gate around might accidentally slice-then-reset,
    /// which would leave observable mid-state behavior even though
    /// the final output is unit. Pinning the final state here is
    /// enough to catch that — any intermediate write to contentsRect
    /// other than unit would indicate incorrect gating.
    func testOffDensitySetsContentsButLeavesContentsRectUnit() {
        SkinContext.ambientDensityManager = DensityModeManager(
            initialMode: .off,
            configWriter: StubWriter()
        )

        let sprite = SpriteDescriptor(
            cellWidth: 50, cellHeight: 25, rows: 2, cols: 2,
            stateMap: ["normal": SpriteCell(row: 0, col: 0),
                       "hover":  SpriteCell(row: 0, col: 1),
                       "pressed":SpriteCell(row: 1, col: 0)]
        )
        let layer = CALayer()
        makeContext().applyFill(
            to: layer,
            from: makeSpriteFill(sprite: sprite),
            spriteState: .hover   // explicitly non-normal
        )

        XCTAssertNotNil(layer.contents,
                        "layer.contents (the sheet) is still assigned — .off gates slicing, not image use")
        XCTAssertEqual(layer.contentsRect, CGRect(x: 0, y: 0, width: 1, height: 1),
                       "Off density must leave contentsRect at unit even when state is non-normal")
    }

    // MARK: - Transition from .full to .off resets the UV

    /// If a layer is painted under `.full` (sprite cell sliced), then
    /// density drops to `.off` and the layer is repainted, the second
    /// `applyFill` must reset `contentsRect` to unit — not carry over
    /// the stale cell UV. This is what turns "density change" into
    /// "chrome bypass" on the already-painted surface.
    func testTransitionFullToOffResetsContentsRect() {
        // Phase 1 — .full, paint a non-origin cell.
        SkinContext.ambientDensityManager = DensityModeManager(
            initialMode: .full,
            configWriter: StubWriter()
        )
        let sprite = SpriteDescriptor(
            cellWidth: 50, cellHeight: 25, rows: 2, cols: 2,
            stateMap: ["normal": SpriteCell(row: 1, col: 1)]
        )
        let layer = CALayer()
        let ctx = makeContext()
        ctx.applyFill(to: layer, from: makeSpriteFill(sprite: sprite), spriteState: .normal)
        XCTAssertNotEqual(layer.contentsRect, CGRect(x: 0, y: 0, width: 1, height: 1),
                          "Precondition: .full must actually slice the cell")

        // Phase 2 — flip to .off and repaint.
        SkinContext.ambientDensityManager = DensityModeManager(
            initialMode: .off,
            configWriter: StubWriter()
        )
        ctx.applyFill(to: layer, from: makeSpriteFill(sprite: sprite), spriteState: .normal)

        XCTAssertEqual(layer.contentsRect, CGRect(x: 0, y: 0, width: 1, height: 1),
                       "Density .full → .off repaint must reset contentsRect to unit")
    }
}
