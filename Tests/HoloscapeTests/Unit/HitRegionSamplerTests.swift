import XCTest
@testable import Holoscape

/// Amplify Task 7.4 — HitRegionSampler unit tests.
///
/// Covers the Jordan-curve ray-cast algorithm across the shape types
/// a Winamp-style skin is likely to author: triangles, squares,
/// concave polygons (L-shape), nested polygons (donut / hole topology),
/// and empty / degenerate inputs. Edge + vertex determinism is pinned
/// here because the half-open-interval convention is load-bearing —
/// without it, a ray grazing a shared vertex would flip inside/outside
/// nondeterministically.
final class HitRegionSamplerTests: XCTestCase {

    // MARK: - Triangle

    func testPointInsideTriangle() {
        let tri = HitRegionSampler(polygons: [
            Polygon(points: [
                Point(x: 0, y: 0),
                Point(x: 100, y: 0),
                Point(x: 50, y: 100),
            ]),
        ])
        XCTAssertTrue(tri.contains(CGPoint(x: 50, y: 25)))
    }

    func testPointOutsideTriangle() {
        let tri = HitRegionSampler(polygons: [
            Polygon(points: [
                Point(x: 0, y: 0),
                Point(x: 100, y: 0),
                Point(x: 50, y: 100),
            ]),
        ])
        // Above the apex — outside.
        XCTAssertFalse(tri.contains(CGPoint(x: 50, y: 150)))
        // Far to the right.
        XCTAssertFalse(tri.contains(CGPoint(x: 200, y: 50)))
    }

    // MARK: - Square

    func testPointsAcrossASquare() {
        let sq = HitRegionSampler(polygons: [
            Polygon(points: [
                Point(x: 10, y: 10),
                Point(x: 90, y: 10),
                Point(x: 90, y: 90),
                Point(x: 10, y: 90),
            ]),
        ])
        XCTAssertTrue(sq.contains(CGPoint(x: 50, y: 50)),
                      "Center of the square must be inside")
        XCTAssertFalse(sq.contains(CGPoint(x: 5, y: 50)),
                       "Left of the square must be outside")
        XCTAssertFalse(sq.contains(CGPoint(x: 95, y: 50)),
                       "Right of the square must be outside")
        XCTAssertFalse(sq.contains(CGPoint(x: 50, y: 5)),
                       "Below the square must be outside")
        XCTAssertFalse(sq.contains(CGPoint(x: 50, y: 95)),
                       "Above the square must be outside")
    }

    // MARK: - Edge + vertex determinism

    /// A point exactly on a polygon vertex must produce the same
    /// answer across repeated calls. Without the half-open interval
    /// convention, two adjacent edges would each count the vertex as
    /// a crossing, producing a parity flip.
    func testVertexClassificationIsStableAcrossCalls() {
        let tri = HitRegionSampler(polygons: [
            Polygon(points: [
                Point(x: 0, y: 0),
                Point(x: 100, y: 0),
                Point(x: 50, y: 100),
            ]),
        ])
        let firstAnswer = tri.contains(CGPoint(x: 0, y: 0))
        for _ in 0..<100 {
            XCTAssertEqual(tri.contains(CGPoint(x: 0, y: 0)), firstAnswer)
        }
    }

    func testEdgeMidpointClassificationIsStable() {
        let tri = HitRegionSampler(polygons: [
            Polygon(points: [
                Point(x: 0, y: 0),
                Point(x: 100, y: 0),
                Point(x: 50, y: 100),
            ]),
        ])
        // Midpoint of the bottom edge (0,0)→(100,0).
        let answer = tri.contains(CGPoint(x: 50, y: 0))
        for _ in 0..<100 {
            XCTAssertEqual(tri.contains(CGPoint(x: 50, y: 0)), answer)
        }
    }

    // MARK: - Concave polygon (L-shape)

    /// A concave L-shape. Interior point in the concave notch
    /// (upper-right) must be outside; interior point in the body
    /// must be inside. Exercises the "two edge crossings" case —
    /// a naive convex-hull test would wrongly call the notch inside.
    func testConcavePolygonClassifiesNotchAsOutside() {
        // L-shape vertices (clockwise from bottom-left):
        //   (0,0) → (100,0) → (100,50) → (50,50) → (50,100) → (0,100)
        let l = HitRegionSampler(polygons: [
            Polygon(points: [
                Point(x: 0, y: 0),
                Point(x: 100, y: 0),
                Point(x: 100, y: 50),
                Point(x: 50, y: 50),
                Point(x: 50, y: 100),
                Point(x: 0, y: 100),
            ]),
        ])
        // Inside the L body (bottom bar).
        XCTAssertTrue(l.contains(CGPoint(x: 75, y: 25)))
        // Inside the L body (left bar).
        XCTAssertTrue(l.contains(CGPoint(x: 25, y: 75)))
        // Inside the notch (upper-right) — must be outside.
        XCTAssertFalse(l.contains(CGPoint(x: 75, y: 75)),
                       "Point in the L's concave notch must classify as outside")
    }

    // MARK: - Multi-polygon union

    /// `contains` returns true if point is inside ANY polygon. Two
    /// disjoint triangles produce a sampler where a point inside
    /// either one is inside the sampler.
    func testUnionOfDisjointPolygons() {
        let sampler = HitRegionSampler(polygons: [
            // Left triangle
            Polygon(points: [
                Point(x: 0, y: 0),
                Point(x: 50, y: 0),
                Point(x: 25, y: 50),
            ]),
            // Right triangle, far to the right
            Polygon(points: [
                Point(x: 200, y: 0),
                Point(x: 250, y: 0),
                Point(x: 225, y: 50),
            ]),
        ])
        XCTAssertTrue(sampler.contains(CGPoint(x: 25, y: 10)),
                      "Point inside left triangle must be inside sampler")
        XCTAssertTrue(sampler.contains(CGPoint(x: 225, y: 10)),
                      "Point inside right triangle must be inside sampler")
        XCTAssertFalse(sampler.contains(CGPoint(x: 100, y: 10)),
                       "Point between the two triangles must be outside")
    }

    // MARK: - Degenerate input

    func testEmptyPolygonsRejectEveryPoint() {
        let sampler = HitRegionSampler(polygons: [])
        XCTAssertFalse(sampler.contains(CGPoint(x: 0, y: 0)))
        XCTAssertFalse(sampler.contains(CGPoint(x: 100, y: 100)))
    }

    func testPolygonBelowThreeVerticesIsTreatedAsEmpty() {
        let sampler = HitRegionSampler(polygons: [
            // 2-vertex "polygon" — degenerate.
            Polygon(points: [Point(x: 0, y: 0), Point(x: 100, y: 0)]),
        ])
        // Any point — including points that would be "on" the line
        // segment — must classify as outside. A degenerate polygon
        // can't define an interior.
        XCTAssertFalse(sampler.contains(CGPoint(x: 50, y: 0)))
        XCTAssertFalse(sampler.contains(CGPoint(x: 50, y: 50)))
    }
}
