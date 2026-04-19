import XCTest
import SwiftCheck
@testable import Holoscape

/// Amplify Property 16 — Drag region HIG warning fires on small
/// bounds (Requirements 4.5, 15.5).
///
/// Apple HIG mandates a 44×44 minimum touch target. `SkinEngine.
/// resolveDragRegions` emits an NSLog warning for any polygon whose
/// bounding box falls below that threshold. The warning is
/// behavior-free at runtime (we still use the region) — it's an
/// authoring-time signal to skin authors.
///
/// NSLog can't easily be intercepted in-process without swizzling,
/// so this property test pins the PREDICATE the warning uses:
/// `ResolvedDragRegion.boundingBox.width < 44 || .height < 44`.
/// Any region whose bbox meets that predicate is "small" by HIG
/// rules; any region that doesn't is acceptable.
///
/// The property confirms the predicate agrees with `boundingBox`
/// for arbitrary polygon sets — no false negatives (region with
/// a 40px edge flagged as HIG-compliant) and no false positives
/// (region with a 100px edge flagged as violating HIG).
final class DragRegionHIGWarningPropertyTests: XCTestCase {

    // MARK: - Generators

    /// Random coordinate in [0, 500].
    private static var coord: Gen<Double> {
        Int.arbitrary.suchThat { $0 >= 0 && $0 <= 500 }.map { Double($0) }
    }

    /// Random coordinate in [0, 30] — produces polygons that will
    /// fit inside a 44×44 bounding box. Used to shape inputs that
    /// MUST trip the HIG predicate.
    private static var tinyCoord: Gen<Double> {
        Int.arbitrary.suchThat { $0 >= 0 && $0 <= 30 }.map { Double($0) }
    }

    // MARK: - Properties

    /// A polygon whose x/y ranges both fit in [0, 30] has a bbox
    /// under 44×44 — the HIG predicate MUST trip.
    func testTinyPolygonsAlwaysTripHIGPredicate() {
        property("polygons with all coords in [0, 30] always violate 44×44") <- forAll(
            Self.tinyCoord, Self.tinyCoord,
            Self.tinyCoord, Self.tinyCoord,
            Self.tinyCoord, Self.tinyCoord
        ) { (x1: Double, y1: Double,
             x2: Double, y2: Double,
             x3: Double, y3: Double) in
            let region = ResolvedDragRegion(
                polygons: [Polygon(points: [
                    Point(x: x1, y: y1),
                    Point(x: x2, y: y2),
                    Point(x: x3, y: y3),
                ])],
                modifier: .none
            )
            let bbox = region.boundingBox
            return bbox.width < 44 || bbox.height < 44
        }
    }

    /// A polygon that spans (0,0) to (>=44, >=44) passes the HIG
    /// predicate — no warning would fire.
    func testLargePolygonsPassHIGPredicate() {
        property("polygons covering 100×100 never violate 44×44") <- forAll(
            Int.arbitrary.suchThat { $0 >= 0 && $0 <= 10 }.map { Double($0) },
            Int.arbitrary.suchThat { $0 >= 0 && $0 <= 10 }.map { Double($0) }
        ) { (jitterX: Double, jitterY: Double) in
            let region = ResolvedDragRegion(
                polygons: [Polygon(points: [
                    Point(x: jitterX, y: jitterY),
                    Point(x: 100 + jitterX, y: jitterY),
                    Point(x: 50 + jitterX, y: 100 + jitterY),
                ])],
                modifier: .none
            )
            let bbox = region.boundingBox
            return bbox.width >= 44 && bbox.height >= 44
        }
    }

    /// The HIG predicate reflects the actual axis-aligned bbox — it
    /// doesn't miss regions whose bbox height is under 44 just because
    /// width isn't. This property specifically exercises the `||`
    /// (either axis) rule.
    func testEitherAxisUnderFortyFourTripsHIGPredicate() {
        property("a polygon wide but short (height < 44) trips HIG") <- forAll(
            Self.coord, Self.coord, Self.coord
        ) { (y1: Double, y2: Double, y3: Double) in
            // Collapse y-range into [0, 30] so the bbox is < 44 tall.
            let narrowY1 = y1.truncatingRemainder(dividingBy: 30)
            let narrowY2 = y2.truncatingRemainder(dividingBy: 30)
            let narrowY3 = y3.truncatingRemainder(dividingBy: 30)
            let region = ResolvedDragRegion(
                polygons: [Polygon(points: [
                    Point(x: 0, y: narrowY1),
                    Point(x: 500, y: narrowY2),  // wide
                    Point(x: 250, y: narrowY3),
                ])],
                modifier: .none
            )
            let bbox = region.boundingBox
            // Width is 500 — passes. Height must be under 44 — trips.
            return bbox.height < 44
        }
    }
}
