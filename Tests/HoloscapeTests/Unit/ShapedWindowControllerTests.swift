import XCTest
import AppKit
@testable import Holoscape

/// Amplify Task 5.5 — ShapedWindowController unit tests.
///
/// Covers the three static / near-static surfaces: env-flag reading,
/// validate's rejection cases (mask-is-post-MVP, out-of-bounds polygon,
/// empty polygons, too-few-vertex polygons), boundingBox math, and
/// buildMaskLayer's CAShapeLayer construction. reconstructWindow has
/// its own integration test (Task 5.6) since it requires a real
/// NSWindow and responder chain.
@MainActor
final class ShapedWindowControllerTests: XCTestCase {

    // MARK: - Feature-flag reading

    func testFeatureFlagOffWhenEnvVarAbsent() {
        let controller = ShapedWindowController(environment: [:])
        XCTAssertFalse(controller.featureFlagEnabled)
    }

    func testFeatureFlagOffWhenEnvVarZero() {
        let controller = ShapedWindowController(
            environment: ["HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS": "0"]
        )
        XCTAssertFalse(controller.featureFlagEnabled)
    }

    func testFeatureFlagOffOnGarbageValue() {
        let controller = ShapedWindowController(
            environment: ["HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS": "true"]
        )
        XCTAssertFalse(controller.featureFlagEnabled,
                       "Only '1' activates the flag — 'true' / 'yes' etc must NOT turn it on")
    }

    func testFeatureFlagOnWhenEnvVarOne() {
        let controller = ShapedWindowController(
            environment: ["HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS": "1"]
        )
        XCTAssertTrue(controller.featureFlagEnabled)
    }

    // MARK: - validate — kind: mask rejection (Requirement 2.9)

    func testMaskKindIsRejectedAsPostMVP() {
        let descriptor = WindowShapeDescriptor(
            kind: .mask,
            polygons: nil,
            maskPath: "assets/mask.png"
        )
        let resolved = ShapedWindowController.validate(
            descriptor,
            against: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        XCTAssertNil(resolved,
                     "kind: mask must reject at validate time — mask is post-MVP per Req 2.9")
    }

    // MARK: - validate — polygon validation (Requirement 2.4)

    func testValidPolygonsReturnResolvedShape() {
        let descriptor = WindowShapeDescriptor(
            kind: .polygons,
            polygons: [
                Polygon(points: [
                    Point(x: 10, y: 10),
                    Point(x: 100, y: 10),
                    Point(x: 100, y: 100),
                    Point(x: 10, y: 100),
                ]),
            ],
            maskPath: nil
        )
        let resolved = ShapedWindowController.validate(
            descriptor,
            against: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        XCTAssertNotNil(resolved)
        guard let resolved, case .polygons(let polys) = resolved.kind else {
            XCTFail("Expected .polygons kind")
            return
        }
        XCTAssertEqual(polys.count, 1)
        XCTAssertEqual(polys.first?.points.count, 4)
    }

    func testEmptyPolygonArrayIsRejected() {
        let descriptor = WindowShapeDescriptor(
            kind: .polygons,
            polygons: [],
            maskPath: nil
        )
        let resolved = ShapedWindowController.validate(
            descriptor,
            against: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        XCTAssertNil(resolved)
    }

    func testPolygonsWithFewerThanThreeVerticesAreDropped() {
        let descriptor = WindowShapeDescriptor(
            kind: .polygons,
            polygons: [
                Polygon(points: [Point(x: 0, y: 0), Point(x: 1, y: 0)]),  // invalid
                Polygon(points: [  // valid triangle
                    Point(x: 0, y: 0),
                    Point(x: 100, y: 0),
                    Point(x: 50, y: 100),
                ]),
            ],
            maskPath: nil
        )
        let resolved = ShapedWindowController.validate(
            descriptor,
            against: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        XCTAssertNotNil(resolved, "The valid triangle must survive even though a sibling was dropped")
        if let resolved, case .polygons(let polys) = resolved.kind {
            XCTAssertEqual(polys.count, 1)
        } else {
            XCTFail("Expected polygons kind")
        }
    }

    func testAllPolygonsInvalidRejectsWholeDescriptor() {
        let descriptor = WindowShapeDescriptor(
            kind: .polygons,
            polygons: [
                Polygon(points: [Point(x: 0, y: 0)]),
                Polygon(points: []),
            ],
            maskPath: nil
        )
        let resolved = ShapedWindowController.validate(
            descriptor,
            against: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        XCTAssertNil(resolved)
    }

    func testOutOfBoundsPolygonRejectsWholeDescriptor() {
        // Polygon bbox entirely to the right of content bounds.
        // Requirement 2.4 — the whole descriptor is rejected (not just
        // the bad polygon dropped) because out-of-bounds is a manifest
        // authoring error, not a per-polygon fallback case.
        let descriptor = WindowShapeDescriptor(
            kind: .polygons,
            polygons: [
                Polygon(points: [
                    Point(x: 9000, y: 100),
                    Point(x: 9100, y: 100),
                    Point(x: 9050, y: 200),
                ]),
            ],
            maskPath: nil
        )
        let resolved = ShapedWindowController.validate(
            descriptor,
            against: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        XCTAssertNil(resolved)
    }

    func testPolygonTouchingContentBoundsEdgeIsAccepted() {
        // bbox intersects the edge — should validate.
        let descriptor = WindowShapeDescriptor(
            kind: .polygons,
            polygons: [
                Polygon(points: [
                    Point(x: 790, y: 100),
                    Point(x: 810, y: 100),
                    Point(x: 800, y: 200),
                ]),
            ],
            maskPath: nil
        )
        let resolved = ShapedWindowController.validate(
            descriptor,
            against: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        XCTAssertNotNil(resolved,
                        "Polygon straddling the bounds edge must validate — partial overlap is not 'entirely outside'")
    }

    // MARK: - boundingBox math

    func testBoundingBoxOfTriangle() {
        let tri = Polygon(points: [
            Point(x: 10, y: 20),
            Point(x: 50, y: 80),
            Point(x: 30, y: 50),
        ])
        let bbox = ShapedWindowController.boundingBox(of: tri)
        XCTAssertEqual(bbox, CGRect(x: 10, y: 20, width: 40, height: 60))
    }

    func testBoundingBoxOfEmptyPolygonIsZero() {
        let empty = Polygon(points: [])
        XCTAssertEqual(ShapedWindowController.boundingBox(of: empty), .zero)
    }

    // MARK: - buildMaskLayer

    func testBuildMaskLayerProducesCAShapeLayerWithPolygonPath() {
        let controller = ShapedWindowController(
            environment: ["HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS": "1"]
        )
        let shape = ResolvedWindowShape(kind: .polygons([
            Polygon(points: [
                Point(x: 0, y: 0),
                Point(x: 100, y: 0),
                Point(x: 50, y: 100),
            ]),
        ]))
        let mask = controller.buildMaskLayer(
            for: shape,
            in: CGRect(x: 0, y: 0, width: 200, height: 200)
        )
        XCTAssertNotNil(mask)
        let shapeLayer = mask as? CAShapeLayer
        XCTAssertNotNil(shapeLayer, "Mask must be a CAShapeLayer so the mask clips to the path")
        XCTAssertNotNil(shapeLayer?.path,
                        "CAShapeLayer must have a non-nil path — empty paths would mask away the whole window")
        XCTAssertEqual(shapeLayer?.frame, CGRect(x: 0, y: 0, width: 200, height: 200))
    }

    // MARK: - reconstructWindow (Task 5.6 integration coverage, unit-style)

    /// Rectangular → shaped → rectangular sequence must preserve frame
    /// across every reconstruction. Spec's load-bearing invariant — a
    /// skin switch should never teleport the user's window.
    func testReconstructWindowPreservesFrameAcrossShapedRoundTrip() throws {
        let controller = ShapedWindowController(
            environment: ["HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS": "1"]
        )
        // Pass the contentRect; AppKit grows the outer frame to include
        // the titlebar for `.titled` style. Read back `rect.frame` to
        // get the actual outer frame — that's what must be preserved
        // across reconstruction.
        let rect = NSWindow(
            contentRect: NSRect(x: 200, y: 150, width: 900, height: 650),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        let preservedFrame = rect.frame
        let rectContentView = try XCTUnwrap(rect.contentView)
        let contentView = NSView(frame: rectContentView.bounds)
        contentView.wantsLayer = true
        rect.contentView = contentView

        // Rectangular → shaped
        let shape = ResolvedWindowShape(kind: .polygons([
            Polygon(points: [Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 50, y: 100)]),
        ]))
        let shapedResult = controller.reconstructWindow(
            currentWindow: rect,
            contentView: contentView,
            targetShape: shape
        )
        XCTAssertEqual(shapedResult.newWindow.frame, preservedFrame,
                       "Shaped window must inherit the rectangular window's outer frame")
        XCTAssertTrue(shapedResult.newWindow.styleMask.contains(.borderless),
                      "Shaped window must use borderless style mask")
        XCTAssertFalse(shapedResult.newWindow.isOpaque)

        // Shaped → rectangular
        let backResult = controller.reconstructWindow(
            currentWindow: shapedResult.newWindow,
            contentView: contentView,
            targetShape: nil
        )
        XCTAssertEqual(backResult.newWindow.frame, preservedFrame,
                       "Round-trip back to rectangular must preserve the original frame")
        XCTAssertTrue(backResult.newWindow.styleMask.contains(.titled),
                      "Rectangular window must use titled style mask")
        XCTAssertTrue(backResult.newWindow.isOpaque)
    }

    /// Content view must migrate to the reconstructed window. A stale
    /// reference would mean the reconstructed window shows nothing.
    func testReconstructWindowMigratesContentView() throws {
        let controller = ShapedWindowController(
            environment: ["HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS": "1"]
        )
        let rect = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let rectContentView = try XCTUnwrap(rect.contentView)
        let contentView = NSView(frame: rectContentView.bounds)
        contentView.wantsLayer = true
        let marker = NSView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
        contentView.addSubview(marker)
        rect.contentView = contentView

        let shape = ResolvedWindowShape(kind: .polygons([
            Polygon(points: [Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 0, y: 10)]),
        ]))
        let result = controller.reconstructWindow(
            currentWindow: rect,
            contentView: contentView,
            targetShape: shape
        )

        XCTAssertTrue(result.newWindow.contentView === contentView,
                      "Reconstructed window must carry the same contentView instance")
        XCTAssertTrue(result.newWindow.contentView?.subviews.contains(marker) ?? false,
                      "Content view's subview tree must survive the migration")
    }

    /// Card #6036 regression pin — reconstructed windows must opt out
    /// of AppKit's legacy `isReleasedWhenClosed` behaviour. The default
    /// (true) combined with Swift ARC caused a double-release when
    /// `applyWindowShape` called `close()` on the old window; a
    /// scheduled `_NSWindowTransformAnimation.dealloc` then landed on a
    /// zombie. The live-window crash itself requires a real compositor
    /// commit (Mac-Mini UI test) — this headless assertion pins the
    /// fix against accidental regression in the construction path.
    func testReconstructedWindowOptsOutOfReleaseWhenClosed() throws {
        let controller = ShapedWindowController(
            environment: ["HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS": "1"]
        )
        let rect = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: try XCTUnwrap(rect.contentView).bounds)
        rect.contentView = contentView

        let shape = ResolvedWindowShape(kind: .polygons([
            Polygon(points: [Point(x: 0, y: 0), Point(x: 10, y: 0), Point(x: 0, y: 10)]),
        ]))
        let shapedResult = controller.reconstructWindow(
            currentWindow: rect,
            contentView: contentView,
            targetShape: shape
        )
        XCTAssertFalse(shapedResult.newWindow.isReleasedWhenClosed,
                       "Shaped reconstruction must clear isReleasedWhenClosed — default true causes double-release with ARC (card #6036)")

        let rectResult = controller.reconstructWindow(
            currentWindow: shapedResult.newWindow,
            contentView: contentView,
            targetShape: nil
        )
        XCTAssertFalse(rectResult.newWindow.isReleasedWhenClosed,
                       "Rectangular reconstruction must also clear isReleasedWhenClosed — same double-release risk")
    }

    func testBuildMaskLayerUnionsMultiplePolygons() {
        // The mask path must contain moves + lines for every polygon.
        // We assert the path bounding box covers the union of both
        // polygons' bounding boxes, which is a proxy for "both shapes
        // are in the path" without needing CGPath element enumeration.
        let controller = ShapedWindowController(
            environment: ["HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS": "1"]
        )
        let shape = ResolvedWindowShape(kind: .polygons([
            Polygon(points: [  // left triangle
                Point(x: 0, y: 0),
                Point(x: 50, y: 0),
                Point(x: 25, y: 50),
            ]),
            Polygon(points: [  // right triangle
                Point(x: 100, y: 0),
                Point(x: 200, y: 0),
                Point(x: 150, y: 50),
            ]),
        ]))
        let mask = controller.buildMaskLayer(
            for: shape,
            in: CGRect(x: 0, y: 0, width: 300, height: 300)
        ) as? CAShapeLayer
        XCTAssertNotNil(mask?.path)
        let bbox = mask!.path!.boundingBox
        XCTAssertEqual(bbox.minX, 0, accuracy: 0.1)
        XCTAssertEqual(bbox.maxX, 200, accuracy: 0.1,
                       "Combined path bbox must reach the right triangle's right edge")
        XCTAssertEqual(bbox.minY, 0, accuracy: 0.1)
        XCTAssertEqual(bbox.maxY, 50, accuracy: 0.1)
    }
}
