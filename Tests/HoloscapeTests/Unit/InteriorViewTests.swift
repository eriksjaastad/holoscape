import XCTest
import AppKit
@testable import Holoscape

/// Chrome v4 Task 5.4 — Component 2 invariants.
///
/// Pins the load-bearing InteriorView contracts:
/// - `computedFrame` performs top-left-to-AppKit conversion correctly
///   (Property 3 — InteriorView frame tracks interiorRect exactly).
/// - `layout()` enforces the frame matches the computed-from-rect
///   expectation against a realistic superview (Req 2.3 / 2.8).
/// - `interiorPath != nil` installs a CAShapeLayer mask; `nil` leaves
///   `layer.mask` unset (Req 2.6 — concave interior masking).
@MainActor
final class InteriorViewTests: XCTestCase {

    // MARK: - computedFrame

    func testComputedFrameFlippedSuperviewAppliesRectDirectly() {
        let rect = SkinRect(x: 40, y: 60, width: 920, height: 600)
        let hostBounds = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let frame = InteriorView.computedFrame(
            interiorRect: rect,
            in: hostBounds,
            superviewIsFlipped: true
        )
        XCTAssertEqual(frame, NSRect(x: 40, y: 60, width: 920, height: 600))
    }

    func testComputedFrameUnflippedSuperviewFlipsY() {
        // Chrome-image top-left origin says interior sits 60px DOWN
        // from the top. On an unflipped (bottom-left) superview, that
        // translates to an AppKit y of `height - 60 - 600 = 40`.
        let rect = SkinRect(x: 40, y: 60, width: 920, height: 600)
        let hostBounds = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let frame = InteriorView.computedFrame(
            interiorRect: rect,
            in: hostBounds,
            superviewIsFlipped: false
        )
        XCTAssertEqual(frame, NSRect(x: 40, y: 40, width: 920, height: 600))
    }

    // MARK: - layout frame invariant

    func testLayoutMovesFrameToComputedPosition() {
        let rect = SkinRect(x: 40, y: 60, width: 920, height: 600)
        let interior = InteriorView(rect: rect, interiorPath: nil)

        // Install under a flipped parent matching the ChromeHostView
        // coordinate convention.
        let parent = FlippedTestHost(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        parent.addSubview(interior)

        // Start with a wrong frame; layout() should correct it.
        interior.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        interior.layout()

        XCTAssertEqual(interior.frame, NSRect(x: 40, y: 60, width: 920, height: 600))
    }

    func testLayoutKeepsFrameStableOnRepeatCalls() {
        let rect = SkinRect(x: 10, y: 20, width: 100, height: 200)
        let interior = InteriorView(rect: rect, interiorPath: nil)
        let parent = FlippedTestHost(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        parent.addSubview(interior)

        interior.layout()
        let first = interior.frame
        interior.layout()
        interior.layout()
        XCTAssertEqual(interior.frame, first,
            "Repeat layout() calls must be idempotent — Property 3 requires exact agreement")
    }

    // MARK: - Mask

    func testInteriorPathNilLeavesMaskUnset() {
        let interior = InteriorView(
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            interiorPath: nil
        )
        XCTAssertNil(interior._testInteriorMask,
            "A nil interiorPath must not allocate a mask (rectangular skins keep layer.mask unset)")
        XCTAssertNil(interior.layer?.mask)
    }

    func testInteriorPathNonNilInstallsShapeLayerMask() {
        let path = [
            Polygon(points: [
                Point(x: 10, y: 10),
                Point(x: 110, y: 10),
                Point(x: 110, y: 110),
                Point(x: 10, y: 110),
            ]),
        ]
        let interior = InteriorView(
            rect: SkinRect(x: 10, y: 10, width: 100, height: 100),
            interiorPath: path
        )
        let mask = interior._testInteriorMask
        XCTAssertNotNil(mask, "Non-nil interiorPath must install a CAShapeLayer mask")
        XCTAssertNotNil(mask?.path)
        XCTAssertEqual(interior.layer?.mask, mask,
            "The mask layer must be wired up as layer.mask")
    }

    func testUpdateInteriorPathNilRemovesExistingMask() {
        let path = [
            Polygon(points: [
                Point(x: 0, y: 0),
                Point(x: 100, y: 0),
                Point(x: 100, y: 100),
            ]),
        ]
        let interior = InteriorView(
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            interiorPath: path
        )
        XCTAssertNotNil(interior._testInteriorMask)

        interior.updateInteriorPath(nil)
        XCTAssertNil(interior._testInteriorMask,
            "Clearing interiorPath must tear down the mask layer")
        XCTAssertNil(interior.layer?.mask)
    }

    func testUpdateInteriorPathSwapsMaskContent() {
        let firstPath = [Polygon(points: [Point(x: 0, y: 0), Point(x: 50, y: 0), Point(x: 50, y: 50)])]
        let secondPath = [Polygon(points: [Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 100, y: 100)])]

        let interior = InteriorView(
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            interiorPath: firstPath
        )
        let firstMask = interior._testInteriorMask
        let firstCGPath = firstMask?.path

        interior.updateInteriorPath(secondPath)
        let secondMask = interior._testInteriorMask
        let secondCGPath = secondMask?.path

        XCTAssertNotNil(firstCGPath)
        XCTAssertNotNil(secondCGPath)
        XCTAssertNotEqual(firstCGPath, secondCGPath,
            "Swapping interiorPath must rebuild the CGPath")
    }

    func testMaskDropsPolygonsBelowThreeVertices() {
        // Polygon with 2 points can't define a region — rebuild should
        // skip it, matching the existing graceful-degradation contract
        // used by ShapedWindowController / drag-region parsing.
        let path = [
            Polygon(points: [Point(x: 0, y: 0), Point(x: 50, y: 0)]),  // skipped
            Polygon(points: [Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 100, y: 100)]),
        ]
        let interior = InteriorView(
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            interiorPath: path
        )
        XCTAssertNotNil(interior._testInteriorMask,
            "At least one valid polygon remains — mask should still install")
    }

    func testAllDegeneratePolygonsInstallsNoMask() {
        // Every polygon has < 3 vertices. An empty CAShapeLayer path
        // clips the view to nothing — the rebuild must instead install
        // no mask at all (graceful degradation per Req 13.5).
        let path = [
            Polygon(points: [Point(x: 0, y: 0), Point(x: 50, y: 0)]),
            Polygon(points: [Point(x: 10, y: 10)]),
            Polygon(points: []),
        ]
        let interior = InteriorView(
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            interiorPath: path
        )
        XCTAssertNil(interior._testInteriorMask,
            "All-degenerate path must leave the view unmasked, not install an empty mask that clips everything")
        XCTAssertNil(interior.layer?.mask)
    }

    func testUpdateInteriorPathAllDegenerateTearsDownExistingMask() {
        // Start with a valid mask, then swap to all-degenerate — the
        // existing mask must come down, not stay installed with an
        // empty path.
        let valid = [Polygon(points: [Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 100, y: 100)])]
        let interior = InteriorView(
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            interiorPath: valid
        )
        XCTAssertNotNil(interior._testInteriorMask)

        interior.updateInteriorPath([Polygon(points: [Point(x: 0, y: 0), Point(x: 50, y: 0)])])
        XCTAssertNil(interior._testInteriorMask,
            "Swapping to an all-degenerate path must tear down the existing mask")
        XCTAssertNil(interior.layer?.mask)
    }

    // MARK: - isFlipped

    func testIsFlippedTrue() {
        let interior = InteriorView(
            rect: SkinRect(x: 0, y: 0, width: 100, height: 100),
            interiorPath: nil
        )
        XCTAssertTrue(interior.isFlipped,
            "Top-left coords so reparented subviews keep their layout orientation")
    }
}

// MARK: - Test helpers

/// NSView subclass that reports `isFlipped = true`. Used as the
/// parent in layout tests so InteriorView sees a ChromeHostView-like
/// coordinate environment without spinning up the full view graph.
@MainActor
private final class FlippedTestHost: NSView {
    override var isFlipped: Bool { true }
}
