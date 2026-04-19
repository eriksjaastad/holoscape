import CoreGraphics

/// Point-in-polygon test for shaped-window hit testing (Amplify
/// Requirement 3). Pure value type — no AppKit dependency, no
/// mutable state, no actor isolation — so property tests can hammer
/// it without any scaffolding.
///
/// Algorithm: Jordan curve theorem via ray casting. Shoot a horizontal
/// ray from the test point to the right; count edge crossings. Odd
/// count → inside, even → outside.
///
/// Edge / vertex determinism uses the half-open interval convention:
/// an edge from y1 to y2 counts as crossing at exactly one of the
/// endpoints (the one matching `min(y1, y2) <= y < max(y1, y2)`).
/// Without this, a ray that grazes a vertex would double-count two
/// adjacent edges, producing nondeterministic "inside" / "outside"
/// flips on vertex-aligned points.
///
/// Alternative rejected: `CGPath.contains(_:)` — works but incurs a
/// Core Graphics boundary cost per call and can't be property-tested
/// in pure Swift. Ray-cast here is O(vertex count) per point and
/// stays well under the 100 µs / 64 vertices budget (Req 3.4) on
/// Apple Silicon.
struct HitRegionSampler: Equatable {
    /// Polygons whose union defines the "inside" region. A point
    /// inside ANY polygon is considered inside the sampler.
    let polygons: [Polygon]

    /// Returns `true` if `point` lies inside at least one polygon's
    /// interior (or deterministically-classified boundary). Short-
    /// circuits on first inside-hit so multi-polygon skins stay
    /// O(total vertices) in the worst case, not O(polygons × vertices).
    func contains(_ point: CGPoint) -> Bool {
        for polygon in polygons where Self.pointInPolygon(point, polygon: polygon) {
            return true
        }
        return false
    }

    /// Ray-cast point-in-polygon. Half-open interval convention on `y`:
    /// an edge whose endpoints straddle the ray counts exactly once,
    /// even if the ray passes through a vertex.
    private static func pointInPolygon(_ point: CGPoint, polygon: Polygon) -> Bool {
        let pts = polygon.points
        guard pts.count >= 3 else { return false }

        var inside = false
        var j = pts.count - 1
        for i in 0..<pts.count {
            let yi = pts[i].y
            let yj = pts[j].y
            let xi = pts[i].x
            let xj = pts[j].x

            // Half-open test: (yi <= point.y < yj) XOR (yj <= point.y < yi).
            // Rewritten as the canonical "one endpoint above, one below
            // or on the ray" predicate:
            let intersectsY = (yi > point.y) != (yj > point.y)
            if intersectsY {
                // Compute x-coord of the edge at point.y. If it's to
                // the right of point.x, the ray (going right) crosses
                // this edge.
                let slope = (xj - xi) / (yj - yi)
                let crossingX = xi + (point.y - yi) * slope
                if point.x < crossingX {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }
}
