import XCTest
import AppKit
@testable import Holoscape

/// Amplify Task 7.2 — ShapedContentView hitTest override.
///
/// Pins the click-through contract: when a sampler is installed and
/// a point falls OUTSIDE the polygon region, `hitTest(_:)` returns
/// nil so the window server passes the event through. When no sampler
/// is installed, behavior is identical to a plain NSView.
@MainActor
final class ShapedContentViewTests: XCTestCase {

    func testHitTestWithoutSamplerDelegatesToSuper() {
        let view = ShapedContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let child = NSView(frame: NSRect(x: 50, y: 50, width: 100, height: 100))
        view.addSubview(child)

        // super.hitTest returns the deepest hittable subview at the
        // point, or the view itself. Without a sampler, ShapedContentView
        // is identical to a plain NSView.
        let insideChild = view.hitTest(NSPoint(x: 75, y: 75))
        XCTAssertNotNil(insideChild,
                        "With no sampler, every in-bounds point must resolve to some view")
    }

    func testHitTestWithSamplerRejectsOutsidePoints() {
        let view = ShapedContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        // Triangle covering the left half of the view.
        view.sampler = HitRegionSampler(polygons: [
            Polygon(points: [
                Point(x: 0, y: 0),
                Point(x: 100, y: 0),
                Point(x: 50, y: 200),
            ]),
        ])

        // Point inside the triangle — inside the sampler.
        XCTAssertNotNil(view.hitTest(NSPoint(x: 50, y: 50)),
                        "Inside-polygon point must resolve to a view (click-through off)")
        // Point outside the triangle, inside the view bounds — click-through.
        XCTAssertNil(view.hitTest(NSPoint(x: 180, y: 100)),
                     "Outside-polygon point must return nil so the window server passes the event through")
    }

    func testHitTestWithNilSamplerAfterHavingSamplerClearsBehavior() {
        // Matches the MainWindowController transition-out-of-shaped
        // path: sampler is set, later cleared, and hitTest must
        // revert to super.hitTest (accept every point).
        let view = ShapedContentView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.sampler = HitRegionSampler(polygons: [
            Polygon(points: [
                Point(x: 0, y: 0),
                Point(x: 10, y: 0),
                Point(x: 5, y: 10),
            ]),
        ])
        XCTAssertNil(view.hitTest(NSPoint(x: 100, y: 100)),
                     "Precondition: sampler rejects the outside point")

        view.sampler = nil
        XCTAssertNotNil(view.hitTest(NSPoint(x: 100, y: 100)),
                        "Clearing the sampler must restore super.hitTest behavior")
    }

    func testWindowDragOverlayHitTestUsesLocalCoordinates() {
        let overlay = WindowDragOverlay(frame: NSRect(x: 100, y: 600, width: 300, height: 40))

        XCTAssertTrue(overlay.hitTest(NSPoint(x: 10, y: 10)) === overlay,
                      "Overlay hitTest receives local coordinates; non-zero frame origins must not offset the point twice")
        XCTAssertNil(overlay.hitTest(NSPoint(x: 310, y: 10)))
    }

    func testChromeDragRegionWinsRootHitTest() {
        let view = ShapedContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let child = NSView(frame: NSRect(x: 0, y: 250, width: 400, height: 50))
        view.addSubview(child)
        view.chromeDragRegions = [CGRect(x: 0, y: 250, width: 400, height: 50)]

        XCTAssertTrue(view.hitTest(NSPoint(x: 100, y: 270)) === view,
                      "Chrome drag regions must route directly to ShapedContentView so performDrag can run")
    }

    func testChromeDragRegionRespectsExclusions() {
        let view = ShapedContentView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let button = NSButton(frame: NSRect(x: 20, y: 260, width: 40, height: 20))
        view.addSubview(button)
        view.chromeDragRegions = [CGRect(x: 0, y: 250, width: 400, height: 50)]
        view.chromeDragExclusionRegions = [button.frame.insetBy(dx: -6, dy: -6)]

        XCTAssertTrue(view.hitTest(NSPoint(x: 30, y: 270)) === button,
                      "Traffic-light exclusions must remain clickable even inside a drag strip")
    }
}
