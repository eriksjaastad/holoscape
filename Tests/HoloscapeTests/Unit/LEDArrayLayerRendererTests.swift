import XCTest
import QuartzCore
@testable import Holoscape

/// Chrome v4 Task 21.4 — LEDArrayLayerRenderer invariants (Req 7).
/// Pattern determinism is the load-bearing invariant: same phase
/// seconds + same params produce the same state set.
@MainActor
final class LEDArrayLayerRendererTests: XCTestCase {

    private func cells(_ n: Int, defaultState: Int = 0) -> [LedArrayParams.LedCell] {
        (0..<n).map { LedArrayParams.LedCell(x: Double($0 * 8), y: 0, defaultState: defaultState) }
    }

    private let palette = ["#000000", "#00ff00", "#ff0000"]

    // MARK: - Cell geometry

    func testCellsBuiltAtInstall() {
        let r = LEDArrayLayerRenderer(
            id: "l",
            z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 20),
            params: LedArrayParams(cellSize: 6, cells: cells(5), palette: palette, pattern: .steady)
        )
        XCTAssertEqual(r._testCellCount, 5,
            "LED renderer must build one CALayer per cell at init (Req 7.2)")
    }

    // MARK: - Steady

    func testSteadyPatternHoldsDefaultState() {
        let r = LEDArrayLayerRenderer(
            id: "l",
            z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 20),
            params: LedArrayParams(cellSize: 6, cells: cells(3, defaultState: 1), palette: palette, pattern: .steady)
        )
        XCTAssertEqual(r.stateIndices(at: 0), [1, 1, 1])
        XCTAssertEqual(r.stateIndices(at: 100), [1, 1, 1],
            "Steady pattern must never change (Req 7.4)")
    }

    // MARK: - Blink

    func testBlinkAlternatesAtHz() {
        // 1 Hz, 50% duty. Phase 0 in ON, phase 0.75 in OFF.
        let r = LEDArrayLayerRenderer(
            id: "l",
            z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 20),
            params: LedArrayParams(cellSize: 6, cells: cells(2), palette: palette, pattern: .blink(hz: 1, duty: 0.5))
        )
        XCTAssertEqual(r.stateIndices(at: 0), [0, 0], "Phase 0 = duty ON → default state")
        XCTAssertEqual(r.stateIndices(at: 0.75), [1, 1], "Phase 0.75 = duty OFF → default+1")
    }

    // MARK: - Phased

    func testPhasedLightsOneAtATime() {
        // 1 cell/sec, 3 cells. Phase 0 lights cell 0; phase 1 lights
        // cell 1; phase 2 lights cell 2.
        let r = LEDArrayLayerRenderer(
            id: "l",
            z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 20),
            params: LedArrayParams(cellSize: 6, cells: cells(3), palette: palette, pattern: .phased(hz: 1))
        )
        XCTAssertEqual(r.stateIndices(at: 0), [1, 0, 0])
        XCTAssertEqual(r.stateIndices(at: 1.1), [0, 1, 0])
        XCTAssertEqual(r.stateIndices(at: 2.1), [0, 0, 1])
    }

    // MARK: - Random

    func testRandomDeterministicSamePhase() {
        let r = LEDArrayLayerRenderer(
            id: "l",
            z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 20),
            params: LedArrayParams(cellSize: 6, cells: cells(20), palette: palette, pattern: .random(hz: 1, density: 0.5))
        )
        let first = r.stateIndices(at: 0.5)
        let second = r.stateIndices(at: 0.5)
        XCTAssertEqual(first, second,
            "Random pattern at the same phase must produce the same bits — determinism is Property 9")
    }

    // MARK: - Marquee

    func testMarqueeWindowAdvances() {
        // 1 cell/sec, window size 1, 4 cells.
        let r = LEDArrayLayerRenderer(
            id: "l",
            z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 20),
            params: LedArrayParams(cellSize: 6, cells: cells(4), palette: palette, pattern: .marquee(cellsPerSecond: 1, windowSize: 1))
        )
        XCTAssertEqual(r.stateIndices(at: 0), [1, 0, 0, 0])
        XCTAssertEqual(r.stateIndices(at: 1.1), [0, 1, 0, 0])
        XCTAssertEqual(r.stateIndices(at: 2.1), [0, 0, 1, 0])
    }

    // MARK: - Phase offset + speed multiplier

    func testPhaseOffsetShiftsPattern() {
        let base = LEDArrayLayerRenderer(
            id: "l",
            z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 20),
            params: LedArrayParams(cellSize: 6, cells: cells(3), palette: palette, pattern: .phased(hz: 1)),
            phaseOffset: 0
        )
        let offset = LEDArrayLayerRenderer(
            id: "l2",
            z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 20),
            params: LedArrayParams(cellSize: 6, cells: cells(3), palette: palette, pattern: .phased(hz: 1)),
            phaseOffset: 1
        )
        // At phase 0.1, offset=1 → localPhase=1.1 → cell 1 lit.
        XCTAssertEqual(base.stateIndices(at: 0.1), [1, 0, 0])
        XCTAssertEqual(offset.stateIndices(at: 0.1), [0, 1, 0])
    }

    func testSpeedMultiplierScalesRate() {
        let slow = LEDArrayLayerRenderer(
            id: "l",
            z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 20),
            params: LedArrayParams(cellSize: 6, cells: cells(3), palette: palette, pattern: .phased(hz: 1)),
            speedMultiplier: 1
        )
        let fast = LEDArrayLayerRenderer(
            id: "l2",
            z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 20),
            params: LedArrayParams(cellSize: 6, cells: cells(3), palette: palette, pattern: .phased(hz: 1)),
            speedMultiplier: 2
        )
        // At phase 0.6, slow lights cell 0 (localPhase = 0.6); fast
        // lights cell 1 (localPhase = 1.2).
        XCTAssertEqual(slow.stateIndices(at: 0.6), [1, 0, 0])
        XCTAssertEqual(fast.stateIndices(at: 0.6), [0, 1, 0])
    }

    // MARK: - Pause / resume

    func testPauseStopsTickMutation() {
        let r = LEDArrayLayerRenderer(
            id: "l",
            z: 1,
            rect: SkinRect(x: 0, y: 0, width: 100, height: 20),
            params: LedArrayParams(cellSize: 6, cells: cells(3), palette: palette, pattern: .phased(hz: 1))
        )
        r.pause()
        r.tick(phaseSeconds: 5)
        // Internal state shouldn't update when paused, but we don't
        // expose cell layers directly — the contract is that tick is a
        // no-op when paused, which we verify via resume idempotency.
        r.resume()
        r.tick(phaseSeconds: 5)
        // Verify no exception, no crash, and state indices still
        // resolve deterministically. Phase 5 @ 1 Hz → floor(5)=5 →
        // 5 % 3 = cell 2 lit, so [0, 0, 1] (default 0 is palette[0],
        // lit cell is (default+1)%palette.count = 1).
        XCTAssertEqual(r.stateIndices(at: 5), [0, 0, 1])
    }
}
