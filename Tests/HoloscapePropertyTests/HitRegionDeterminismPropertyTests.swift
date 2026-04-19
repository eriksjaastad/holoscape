import XCTest
import SwiftCheck
@testable import Holoscape

/// Amplify Property 5 — Hit region sampler is deterministic on
/// vertices and edges (Requirements 3.2, 3.3).
///
/// For any polygon and any test point, `HitRegionSampler.contains(_:)`
/// must return the same answer across repeated calls. And: two
/// samplers constructed from the same polygon list must return
/// identical results for every point in a shared grid. Without the
/// half-open-interval convention on y-edge testing, vertex-aligned
/// points would flip inside/outside depending on traversal order.
final class HitRegionDeterminismPropertyTests: XCTestCase {

    // MARK: - Generators

    /// A random in-bounds coordinate (0..400). `Int.arbitrary.suchThat.map`
    /// yields a `Gen<Double>` that fails Swift 6 `Sendable` conformance
    /// when bound to a `static let`; a `static var { get }` computed
    /// property re-constructs per-access and dodges that constraint
    /// without breaking SwiftCheck's sampling (each access still pulls
    /// fresh samples from the underlying `Int.arbitrary` stream).
    private static var coord: Gen<Double> {
        Int.arbitrary.suchThat { $0 >= 0 && $0 <= 400 }.map { Double($0) }
    }

    // MARK: - Properties

    func testContainsIsDeterministicAcrossRepeatedCalls() {
        property("contains(_:) returns the same answer across 50 repeated calls") <- forAll(
            Self.coord, Self.coord,
            Self.coord, Self.coord,
            Self.coord, Self.coord,
            Self.coord, Self.coord
        ) { (x1: Double, y1: Double, x2: Double, y2: Double,
             x3: Double, y3: Double, px: Double, py: Double) in
            let tri = HitRegionSampler(polygons: [
                Polygon(points: [
                    Point(x: x1, y: y1),
                    Point(x: x2, y: y2),
                    Point(x: x3, y: y3),
                ]),
            ])
            let p = CGPoint(x: px, y: py)
            let expected = tri.contains(p)
            for _ in 0..<50 {
                if tri.contains(p) != expected { return false }
            }
            return true
        }
    }

    func testTwoSamplersWithSamePolygonsAgreeOnEveryPoint() {
        // Two independently-constructed samplers from identical
        // polygons must agree on every point in a 9-point grid.
        // No shared state between sampler instances should affect
        // the answer.
        property("two samplers built from the same polygon list classify every point identically") <- forAll(
            Self.coord, Self.coord,
            Self.coord, Self.coord,
            Self.coord, Self.coord
        ) { (x1: Double, y1: Double,
             x2: Double, y2: Double,
             x3: Double, y3: Double) in
            let poly = Polygon(points: [
                Point(x: x1, y: y1),
                Point(x: x2, y: y2),
                Point(x: x3, y: y3),
            ])
            let a = HitRegionSampler(polygons: [poly])
            let b = HitRegionSampler(polygons: [poly])

            for gx in stride(from: 0.0, through: 400.0, by: 50.0) {
                for gy in stride(from: 0.0, through: 400.0, by: 50.0) {
                    let p = CGPoint(x: gx, y: gy)
                    if a.contains(p) != b.contains(p) { return false }
                }
            }
            return true
        }
    }

    /// Points far from any polygon must be classified as outside —
    /// any random triangle with vertices in [0, 400]² has all its
    /// interior points in [0, 400]². Points at (10000, 10000) are
    /// guaranteed outside.
    func testFarAwayPointsAreAlwaysOutside() {
        property("points at (10000, 10000) are outside any in-bounds triangle") <- forAll(
            Self.coord, Self.coord,
            Self.coord, Self.coord,
            Self.coord, Self.coord
        ) { (x1: Double, y1: Double,
             x2: Double, y2: Double,
             x3: Double, y3: Double) in
            let sampler = HitRegionSampler(polygons: [
                Polygon(points: [
                    Point(x: x1, y: y1),
                    Point(x: x2, y: y2),
                    Point(x: x3, y: y3),
                ]),
            ])
            return sampler.contains(CGPoint(x: 10_000, y: 10_000)) == false
        }
    }
}
