import XCTest
import SwiftCheck
@testable import Holoscape

/// Amplify Property 4 — Shape validation rejects out-of-bounds polygons
/// (Requirements 2.4, 12.7).
///
/// For any `WindowShapeDescriptor` with at least one polygon whose
/// bounding box lies entirely outside the nominal content-view bounds,
/// `ShapedWindowController.validate` returns nil. The reject-the-whole-
/// descriptor rule exists because an out-of-bounds polygon is a
/// manifest authoring bug, not a graceful-degradation case — falling
/// back to "just use the in-bounds polygons" would render a skin
/// that's partially shaped, partially not, which is strictly worse
/// than refusing the shape and falling back to rectangular.
@MainActor
final class ShapeValidationPropertyTests: XCTestCase {

    // MARK: - Generators

    /// Fixed nominal content bounds used by every generated test case.
    /// 800×600 is a reasonable authoring default; the invariant is
    /// independent of the specific numbers.
    private static let contentBounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    /// A random in-bounds vertex.
    private static let inBoundsX: Gen<Double> =
        Int.arbitrary.suchThat { $0 >= 0 && $0 <= 800 }.map { Double($0) }
    private static let inBoundsY: Gen<Double> =
        Int.arbitrary.suchThat { $0 >= 0 && $0 <= 600 }.map { Double($0) }

    /// A vertex far to the right of content bounds. Any three of these
    /// produce a polygon whose bbox is entirely outside.
    private static let farRightX: Gen<Double> =
        Int.arbitrary.suchThat { $0 >= 1000 && $0 <= 5000 }.map { Double($0) }

    // MARK: - Property 4.a: Out-of-bounds polygon rejects whole descriptor

    func testOutOfBoundsPolygonRejectsDescriptor() {
        property("a descriptor containing any out-of-bounds polygon validates to nil") <- forAll(
            Self.farRightX, Self.farRightX, Self.farRightX,
            Self.inBoundsY, Self.inBoundsY, Self.inBoundsY
        ) { (x1: Double, x2: Double, x3: Double,
             y1: Double, y2: Double, y3: Double) in
            // Three points all far to the right → bbox entirely outside
            // the 800-wide content bounds.
            let outOfBounds = Polygon(points: [
                Point(x: x1, y: y1),
                Point(x: x2, y: y2),
                Point(x: x3, y: y3),
            ])
            let descriptor = WindowShapeDescriptor(
                kind: .polygons,
                polygons: [outOfBounds],
                maskPath: nil
            )
            return ShapedWindowController.validate(descriptor, against: Self.contentBounds) == nil
        }
    }

    // MARK: - Property 4.b: Well-formed in-bounds polygon validates

    func testInBoundsTriangleValidates() {
        property("an in-bounds triangle validates to a .polygons resolved shape") <- forAll(
            Self.inBoundsX, Self.inBoundsY,
            Self.inBoundsX, Self.inBoundsY,
            Self.inBoundsX, Self.inBoundsY
        ) { (x1: Double, y1: Double,
             x2: Double, y2: Double,
             x3: Double, y3: Double) in
            // Degenerate triangle (all points collinear) would still
            // validate at the polygon-count level — Polygon.isValid
            // just checks vertex count. Valid-but-zero-area polygons
            // are a separate concern handled by the renderer, not the
            // validator.
            let tri = Polygon(points: [
                Point(x: x1, y: y1),
                Point(x: x2, y: y2),
                Point(x: x3, y: y3),
            ])
            let descriptor = WindowShapeDescriptor(
                kind: .polygons,
                polygons: [tri],
                maskPath: nil
            )
            guard let resolved = ShapedWindowController.validate(descriptor, against: Self.contentBounds),
                  case .polygons(let polys) = resolved.kind else {
                return false
            }
            return polys.count == 1
        }
    }

    // MARK: - Property 4.c: Mask kind is always rejected (Req 2.9)

    func testMaskKindAlwaysRejected() {
        // Regardless of polygons / maskPath contents, kind: mask
        // must reject at validate time — post-MVP per Req 2.9.
        property("kind: mask always validates to nil regardless of other fields") <- forAll(
            Self.inBoundsX, Self.inBoundsY
        ) { (x: Double, y: Double) in
            let descriptor = WindowShapeDescriptor(
                kind: .mask,
                polygons: [
                    Polygon(points: [
                        Point(x: x, y: y),
                        Point(x: x + 10, y: y),
                        Point(x: x, y: y + 10),
                    ]),
                ],
                maskPath: "assets/mask.png"
            )
            return ShapedWindowController.validate(descriptor, against: Self.contentBounds) == nil
        }
    }
}
