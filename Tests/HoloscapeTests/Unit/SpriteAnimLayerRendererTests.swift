import XCTest
import QuartzCore
@testable import Holoscape

/// Chrome v4 Task 21.5 — SpriteAnimLayerRenderer invariants (Req 8).
/// Pins loop/pingPong/once frame resolution + UV rect geometry.
@MainActor
final class SpriteAnimLayerRendererTests: XCTestCase {

    private func params(
        gridRows: Int = 2, gridCols: Int = 4,
        frameCount: Int = 8, fps: Double = 10,
        loop: SpriteAnimParams.Loop = .loop
    ) -> SpriteAnimParams {
        SpriteAnimParams(
            sheet: "sheet.png",
            gridRows: gridRows, gridCols: gridCols,
            frameCount: frameCount, fps: fps, loop: loop
        )
    }

    // MARK: - UV rect geometry

    func testUvRectFirstFrame() {
        let r = SpriteAnimLayerRenderer.uvRect(for: 0, gridRows: 2, gridCols: 4)
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 0.25, height: 0.5))
    }

    func testUvRectMidFrame() {
        // Frame 3 → last column of first row → col=3, row=0.
        let r = SpriteAnimLayerRenderer.uvRect(for: 3, gridRows: 2, gridCols: 4)
        XCTAssertEqual(r, CGRect(x: 0.75, y: 0, width: 0.25, height: 0.5))
    }

    func testUvRectWrapsToNextRow() {
        // Frame 4 → first col of second row.
        let r = SpriteAnimLayerRenderer.uvRect(for: 4, gridRows: 2, gridCols: 4)
        XCTAssertEqual(r, CGRect(x: 0, y: 0.5, width: 0.25, height: 0.5))
    }

    func testUvRectDegenerateGridReturnsUnitSquare() {
        let r = SpriteAnimLayerRenderer.uvRect(for: 0, gridRows: 0, gridCols: 0)
        XCTAssertEqual(r, CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // MARK: - Loop mode

    func testLoopModeWrapsAtFrameCount() {
        let r = SpriteAnimLayerRenderer(
            id: "s", z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            params: params(loop: .loop)
        )
        // At fps=10, phase 0.05 → frame 0; phase 0.85 → frame 8 → wraps to 0.
        XCTAssertEqual(r.frameIndex(at: 0), 0)
        XCTAssertEqual(r.frameIndex(at: 0.85), 0, "Frame 8 wraps to 0 (frameCount = 8)")
    }

    func testLoopModeAdvancesOneFramePerTick() {
        let r = SpriteAnimLayerRenderer(
            id: "s", z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            params: params(loop: .loop)
        )
        XCTAssertEqual(r.frameIndex(at: 0.15), 1)
        XCTAssertEqual(r.frameIndex(at: 0.25), 2)
        XCTAssertEqual(r.frameIndex(at: 0.35), 3)
    }

    // MARK: - Once mode

    func testOnceModeHoldsAtLastFrame() {
        let r = SpriteAnimLayerRenderer(
            id: "s", z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            params: params(loop: .once)
        )
        // 8 frames at 10 fps → animation runs to phase 0.7, then
        // holds frame 7 forever after.
        XCTAssertEqual(r.frameIndex(at: 0.5), 5)
        XCTAssertEqual(r.frameIndex(at: 0.7), 7)
        XCTAssertEqual(r.frameIndex(at: 10), 7,
            ".once mode must hold at frameCount-1 after one pass (Req 8.3)")
    }

    // MARK: - PingPong

    func testPingPongReversesAtEnd() {
        let r = SpriteAnimLayerRenderer(
            id: "s", z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            params: params(loop: .pingPong)
        )
        // 8 frames @ 10 fps. Period = 2*(8-1) = 14. Position 7 = 7,
        // position 8 = 6, position 13 = 1.
        XCTAssertEqual(r.frameIndex(at: 0.7), 7)
        XCTAssertEqual(r.frameIndex(at: 0.8), 6)
        XCTAssertEqual(r.frameIndex(at: 1.3), 1)
        XCTAssertEqual(r.frameIndex(at: 1.4), 0)
    }

    func testPingPongSingleFrameDoesNotOscillate() {
        let r = SpriteAnimLayerRenderer(
            id: "s", z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            params: params(frameCount: 1, loop: .pingPong)
        )
        XCTAssertEqual(r.frameIndex(at: 0), 0)
        XCTAssertEqual(r.frameIndex(at: 5), 0)
    }

    // MARK: - Phase offset + speed multiplier

    func testPhaseOffsetShiftsFrame() {
        let base = SpriteAnimLayerRenderer(
            id: "s", z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            params: params(loop: .loop),
            phaseOffset: 0
        )
        let offset = SpriteAnimLayerRenderer(
            id: "s2", z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            params: params(loop: .loop),
            phaseOffset: 0.2
        )
        // At phase 0, offset=0.2 → localPhase=0.2 → fps 10 → frame 2.
        XCTAssertEqual(base.frameIndex(at: 0), 0)
        XCTAssertEqual(offset.frameIndex(at: 0), 2)
    }

    func testSpeedMultiplierScalesFps() {
        let fast = SpriteAnimLayerRenderer(
            id: "s", z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            params: params(fps: 10, loop: .loop),
            speedMultiplier: 2
        )
        // At phase 0.1, speedMult=2 → localPhase=0.2 → frame 2.
        XCTAssertEqual(fast.frameIndex(at: 0.1), 2)
    }

    // MARK: - Install

    func testInstallPinsFrameAndAddsSublayer() {
        let parent = CALayer()
        let r = SpriteAnimLayerRenderer(
            id: "s", z: 2,
            rect: SkinRect(x: 50, y: 60, width: 200, height: 100),
            params: params()
        )
        r.install(in: parent)
        XCTAssertTrue(parent.sublayers?.contains(r.layer) ?? false)
        XCTAssertEqual(r.layer.frame, NSRect(x: 50, y: 60, width: 200, height: 100))
    }

    func testInitialContentsRectIsFrameZero() {
        let r = SpriteAnimLayerRenderer(
            id: "s", z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            params: params(gridRows: 2, gridCols: 4)
        )
        XCTAssertEqual(r.layer.contentsRect, CGRect(x: 0, y: 0, width: 0.25, height: 0.5))
    }
}
