import XCTest
import SwiftCheck
@testable import Holoscape

/// Property 5 — State variant determinism (Requirements 12.1, 12.2, 12.4, 12.5, 12.6).
///
/// Given the same `(SurfaceKey, ReactiveUniformSnapshot)` pair, the
/// resolved surface must be identical on repeated evaluation. Match
/// evaluation is a pure function of the snapshot; there's no clock,
/// no RNG, no mutation. The property test guards against accidental
/// non-determinism sneaking in via set iteration order (state variants
/// iterate in array order; unordered-dictionary matches combine with AND).
///
/// SwiftCheck's `forAll` requires `Arbitrary` conformance on generated
/// types. Neither `SurfaceKey` nor `ReactiveUniformSnapshot` conform, so
/// this file generates their raw inputs (String for the key, Int32s for
/// the snapshot fields) and constructs the actual values inside each
/// property closure.
@MainActor
final class StateDeterminismPropertyTests: XCTestCase {

    // MARK: - Generators

    /// Generates a `SurfaceKey` raw value — one of the 23 known dot-separated strings.
    private static let surfaceKeyRaw: Gen<String> =
        Gen<String>.fromElements(of: SurfaceKey.allCases.map(\.rawValue))

    /// Small-range Int32 so match conditions like `$gte: 1` / `$eq: 2`
    /// actually fire a meaningful fraction of the time. Unbounded Int32s
    /// would make every variant miss and leave the state codepath unexercised.
    private static let smallInt32: Gen<Int32> =
        Gen<Int32>.fromElements(of: [0, 1, 2, 3, 4, 5])

    /// Build a snapshot from five independent Int32 values.
    private func makeSnapshot(
        agent: Int32,
        command: Int32,
        unread: Int32,
        notification: Int32,
        connection: Int32
    ) -> ReactiveUniformSnapshot {
        let snap = ReactiveUniformSnapshot()
        snap.setAgentState(agent)
        snap.setCommandState(command)
        snap.setChannelState(channelId: 1, isActive: 1, unread: unread)
        snap.setChannelConnectionState(connection)
        snap.setNotificationKind(notification)
        return snap
    }

    // MARK: - Determinism property

    func testCurrentStateIsDeterministic() {
        // For every SurfaceKey and every generated snapshot, evaluate
        // `currentState` 10 times and assert all 10 results are equal.
        // State variants are evaluated in array order with CSS-cascade
        // semantics — any source of nondeterminism would surface here.
        let context = SkinContext.builtInDefaults(reactive: ReactiveUniformSnapshot())

        property("currentState(for:with:) returns identical ResolvedSurface on repeat evaluation") <- forAll(
            Self.surfaceKeyRaw,
            Self.smallInt32,
            Self.smallInt32,
            Self.smallInt32,
            Self.smallInt32,
            Self.smallInt32
        ) { (keyRaw: String, a: Int32, c: Int32, u: Int32, n: Int32, conn: Int32) in
            guard let key = SurfaceKey(rawValue: keyRaw) else { return false }
            let snapshot = self.makeSnapshot(agent: a, command: c, unread: u, notification: n, connection: conn)

            var previous: SkinContext.ResolvedSurface?
            for _ in 0..<10 {
                let resolved = context.currentState(for: key, with: snapshot)
                if let prev = previous, !resolved.isEqual(to: prev) {
                    return false
                }
                previous = resolved
            }
            return true
        }
    }

    // MARK: - Match evaluation determinism (stronger, cheaper)

    func testEvaluateMatchIsDeterministic() {
        // Match evaluation over a random snapshot must also be stable
        // across repeat calls. This is the primitive that `currentState`
        // builds on — covering it directly gives tighter feedback when
        // a regression hits.
        let matchKeyGen = Gen<String>.fromElements(of: [
            "agentState", "commandState", "channelUnread",
            "notificationKind", "channelConnectionState",
        ])
        let opGen = Gen<String>.fromElements(of: ["$eq", "$ne", "$gt", "$gte", "$lt", "$lte"])
        let valueGen: Gen<Double> = Double.arbitrary.suchThat { $0.isFinite && abs($0) <= 10 }

        let context = SkinContext.builtInDefaults(reactive: ReactiveUniformSnapshot())

        property("evaluateMatch returns the same Bool on repeat calls") <- forAll(
            matchKeyGen, opGen, valueGen,
            Self.smallInt32, Self.smallInt32, Self.smallInt32
        ) { (key: String, op: String, value: Double, a: Int32, c: Int32, u: Int32) in
            let snapshot = self.makeSnapshot(agent: a, command: c, unread: u, notification: 0, connection: 0)
            let expr = MatchExpression(conditions: [key: .operators([op: value])])

            let first = context.evaluateMatch(expr, with: snapshot)
            for _ in 0..<5 {
                if context.evaluateMatch(expr, with: snapshot) != first {
                    return false
                }
            }
            return true
        }
    }
}

// MARK: - Equality helpers for ResolvedSurface subset

/// `ResolvedSurface` isn't `Equatable` because `ResolvedFill` holds an
/// `NSImage` reference in the `.image` case. For the determinism test
/// it's enough to compare the fields that matter for state variant
/// evaluation: the resolved fill color/gradient identity, text color,
/// and corner.
private extension SkinContext.ResolvedSurface {
    func isEqual(to other: SkinContext.ResolvedSurface) -> Bool {
        guard fillIsEqual(fill, other.fill) else { return false }
        guard text.color == other.text.color else { return false }
        guard corner == other.corner else { return false }
        return true
    }

    private func fillIsEqual(_ lhs: SkinContext.ResolvedFill, _ rhs: SkinContext.ResolvedFill) -> Bool {
        switch (lhs, rhs) {
        case (.color(let a), .color(let b)):
            return a.cgColor == b.cgColor
        case (.gradient(let dA, let sA), .gradient(let dB, let sB)):
            return dA == dB && sA == sB
        case (.image(let iA, let tA, _), .image(let iB, let tB, _)):
            return iA === iB && tA == tB
        default:
            return false
        }
    }
}
