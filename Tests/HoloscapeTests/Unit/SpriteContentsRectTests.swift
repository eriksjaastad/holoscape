import XCTest
import AppKit
@testable import Holoscape

/// Amplify Task 11.7 — sprite cell UV rendering via `layer.contentsRect`.
///
/// Pins the rendering contract: `applyFill` with a sprite-descriptor
/// fill assigns the FULL sheet to `layer.contents` once, then sets
/// `layer.contentsRect` to the UV rectangle of the current state's
/// cell. State transitions MUST mutate only `contentsRect` — no new
/// image assignments, no bitmap allocations on the hot path. This is
/// the "GPU-friendly sprite" invariant that keeps transitions under
/// the 16ms budget without per-state CGImage work.
@MainActor
final class SpriteContentsRectTests: XCTestCase {

    /// Stub the ambient density manager to `.full` so sprite rendering
    /// actually runs. The minimal-mode short-circuit is covered separately.
    override func setUp() {
        super.setUp()
        let manager = DensityModeManager(
            initialMode: .full,
            configWriter: NoopDensityConfigWriter()
        )
        SkinContext.ambientDensityManager = manager
    }

    override func tearDown() {
        SkinContext.ambientDensityManager = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    /// 100×50 solid-color NSImage for tests. Real bitmap — not a
    /// zero-size placeholder — so `applyFill`'s divisor math computes.
    private func makeFixtureSheet(width: Int = 100, height: Int = 50) -> NSImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    private func makeSpriteFill(
        sprite: SpriteDescriptor
    ) -> SkinContext.ResolvedSurface {
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
        // Minimal context — we only exercise applyFill's rendering,
        // not surface lookup.
        let snap = ReactiveUniformSnapshot()
        return SkinContext(surfaces: [:], reactive: snap)
    }

    // MARK: - UV math at cell boundaries

    func testFirstCellUVIsAtOrigin() {
        let sprite = SpriteDescriptor(
            cellWidth: 50, cellHeight: 25, rows: 2, cols: 2,
            stateMap: ["normal": SpriteCell(row: 0, col: 0)]
        )
        let ctx = makeContext()
        let layer = CALayer()
        ctx.applyFill(to: layer, from: makeSpriteFill(sprite: sprite))
        // 50×25 cell in a 100×50 sheet → UV (0, 0, 0.5, 0.5)
        XCTAssertEqual(layer.contentsRect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(layer.contentsRect.minY, 0, accuracy: 0.001)
        XCTAssertEqual(layer.contentsRect.width, 0.5, accuracy: 0.001)
        XCTAssertEqual(layer.contentsRect.height, 0.5, accuracy: 0.001)
    }

    func testLastCellUVReachesSheetEdge() {
        let sprite = SpriteDescriptor(
            cellWidth: 50, cellHeight: 25, rows: 2, cols: 2,
            stateMap: ["normal": SpriteCell(row: 1, col: 1)]
        )
        let ctx = makeContext()
        let layer = CALayer()
        ctx.applyFill(to: layer, from: makeSpriteFill(sprite: sprite))
        // Bottom-right cell → UV (0.5, 0.5, 0.5, 0.5)
        XCTAssertEqual(layer.contentsRect.minX, 0.5, accuracy: 0.001)
        XCTAssertEqual(layer.contentsRect.minY, 0.5, accuracy: 0.001)
        XCTAssertEqual(layer.contentsRect.maxX, 1.0, accuracy: 0.001)
        XCTAssertEqual(layer.contentsRect.maxY, 1.0, accuracy: 0.001)
    }

    // MARK: - Fallback chain (Req 5.3)

    func testMissingStateFallsBackToNormal() {
        let sprite = SpriteDescriptor(
            cellWidth: 50, cellHeight: 25, rows: 2, cols: 2,
            stateMap: [
                "normal": SpriteCell(row: 0, col: 0),
                // hover missing; caller passes .hover
            ]
        )
        let ctx = makeContext()
        let layer = CALayer()
        ctx.applyFill(to: layer, from: makeSpriteFill(sprite: sprite),
                      spriteState: .hover)
        // Must resolve to normal's cell (0, 0, 0.5, 0.5) since hover
        // isn't mapped.
        XCTAssertEqual(layer.contentsRect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(layer.contentsRect.minY, 0, accuracy: 0.001)
    }

    func testMissingBothStateAndNormalFallsBackToStretch() {
        let sprite = SpriteDescriptor(
            cellWidth: 50, cellHeight: 25, rows: 2, cols: 2,
            stateMap: ["hover": SpriteCell(row: 1, col: 1)]
        )
        let ctx = makeContext()
        let layer = CALayer()
        // Request .pressed — neither pressed nor normal is mapped.
        ctx.applyFill(to: layer, from: makeSpriteFill(sprite: sprite),
                      spriteState: .pressed)
        // Fall back to unit contentsRect + stretch gravity.
        XCTAssertEqual(layer.contentsRect, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(layer.contentsGravity, .resize)
    }

    // MARK: - Single-sheet-contents invariant (Req 5.1, 5.7)

    /// Across multiple applyFill calls with the same sprite + image,
    /// `layer.contents` must reference the same NSImage object — sprite
    /// state transitions must NOT reallocate the bitmap. This is the
    /// "no per-state CGImage re-crop" invariant at the heart of the
    /// contentsRect design (vs the alternative of NSImage-cropping
    /// that was rejected in spec reconciliation).
    func testSheetContentsIsStableAcrossStateTransitions() {
        // Hold the sheet reference explicitly so the identity check
        // doesn't rely on CALayer preserving the NSImage type — on
        // some AppKit paths `layer.contents` can get normalized to
        // CGImageRef, which would break an NSImage===NSImage check.
        // We compare the AnyObject wrappers across CALLS, which is
        // the only cross-call identity the test cares about.
        let sprite = SpriteDescriptor(
            cellWidth: 50, cellHeight: 25, rows: 2, cols: 2,
            stateMap: [
                "normal": SpriteCell(row: 0, col: 0),
                "hover": SpriteCell(row: 0, col: 1),
                "pressed": SpriteCell(row: 1, col: 0),
            ]
        )
        let ctx = makeContext()
        let sheet = makeFixtureSheet(
            width: sprite.cellWidth * sprite.cols,
            height: sprite.cellHeight * sprite.rows
        )
        let surface = SkinContext.ResolvedSurface(
            fill: .image(sheet, .stretch, nil, sprite),
            border: nil, corner: .uniform(0), padding: NSEdgeInsets(),
            shadow: nil, font: nil,
            text: SkinContext.ResolvedText(color: .white, shadow: nil),
            animation: nil, states: []
        )
        let layer = CALayer()

        ctx.applyFill(to: layer, from: surface, spriteState: .normal)
        let afterNormal = layer.contents as AnyObject?

        ctx.applyFill(to: layer, from: surface, spriteState: .hover)
        let afterHover = layer.contents as AnyObject?

        ctx.applyFill(to: layer, from: surface, spriteState: .pressed)
        let afterPressed = layer.contents as AnyObject?

        XCTAssertTrue(afterNormal === afterHover,
                      "layer.contents must be stable across state transitions — Req 5.1 / 5.7")
        XCTAssertTrue(afterHover === afterPressed,
                      "Repeated transitions keep the same sheet; only contentsRect changes")
        // Primary invariant: the sheet we passed in is what the layer
        // ended up referencing (either directly as NSImage, or as a
        // CGImage derived from it — the `as? NSImage` cast handles
        // the former, which is what AppKit uses on main-thread paths).
        XCTAssertTrue(layer.contents as? NSImage === sheet,
                      "layer.contents must hold the sheet NSImage we assigned")
    }

    /// Complement of the above: contentsRect DOES change across
    /// transitions. Without this, state changes would visually pin on
    /// one cell regardless of which state the caller requested.
    func testContentsRectChangesAcrossStateTransitions() {
        let sprite = SpriteDescriptor(
            cellWidth: 50, cellHeight: 25, rows: 2, cols: 2,
            stateMap: [
                "normal": SpriteCell(row: 0, col: 0),
                "hover": SpriteCell(row: 0, col: 1),
            ]
        )
        let ctx = makeContext()
        let surface = makeSpriteFill(sprite: sprite)
        let layer = CALayer()

        ctx.applyFill(to: layer, from: surface, spriteState: .normal)
        let normalRect = layer.contentsRect

        ctx.applyFill(to: layer, from: surface, spriteState: .hover)
        let hoverRect = layer.contentsRect

        XCTAssertNotEqual(normalRect, hoverRect,
                          "contentsRect must mutate on state transitions")
    }

    // MARK: - Density minimal bypass (Req 5.6 / 11.2)

    func testMinimalDensityFallsBackToStretch() {
        // Stub manager to .minimal for this test, restore at end.
        let previous = SkinContext.ambientDensityManager
        defer { SkinContext.ambientDensityManager = previous }

        SkinContext.ambientDensityManager = DensityModeManager(
            initialMode: .minimal,
            configWriter: NoopDensityConfigWriter()
        )

        let sprite = SpriteDescriptor(
            cellWidth: 50, cellHeight: 25, rows: 2, cols: 2,
            stateMap: ["normal": SpriteCell(row: 1, col: 1)]
        )
        let ctx = makeContext()
        let layer = CALayer()
        ctx.applyFill(to: layer, from: makeSpriteFill(sprite: sprite))

        // Density .minimal short-circuits the sprite path — full-sheet
        // stretch via applyTileMode. contentsRect stays unit.
        XCTAssertEqual(layer.contentsRect, CGRect(x: 0, y: 0, width: 1, height: 1),
                       "Density .minimal must fall back to unit contentsRect (Req 5.6)")
    }
}

/// No-op config writer — lets tests construct DensityModeManager
/// without touching disk or a real ConfigService.
private final class NoopDensityConfigWriter: DensityModeConfigWriter {
    func writeDensityMode(_ modeRawValue: String) {}
}
