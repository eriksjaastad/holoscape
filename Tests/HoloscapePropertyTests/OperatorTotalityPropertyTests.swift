import XCTest
import SwiftCheck
@testable import Holoscape

/// Property 6 — Match operator totality (Requirement 12.3).
///
/// `SkinContext.evaluateMatch(_:with:)` must return a `Bool` for every
/// input. No throws, no traps, no nil — unknown keys and unknown
/// operators are logged and treated as non-matching (the production
/// path already guarantees this; the property test ensures it stays
/// that way under random inputs).
///
/// Coverage spans:
///   - Every supported operator (`$eq`, `$ne`, `$gt`, `$gte`, `$lt`, `$lte`)
///   - Bare-scalar shorthand (implicit `$eq`)
///   - Multi-key AND combination
///   - Unknown match keys and unknown operators (must not crash)
///   - `timeSince` nested expressions
@MainActor
final class OperatorTotalityPropertyTests: XCTestCase {

    private let context = SkinContext.builtInDefaults(reactive: ReactiveUniformSnapshot())

    // MARK: - Generators

    private static let knownMatchKey: Gen<String> = Gen<String>.fromElements(of: [
        "agentState", "previousAgentState",
        "commandState", "previousCommandState", "lastCommandExitCode",
        "channelId", "channelIsActive", "channelUnread", "channelConnectionState",
        "notificationKind", "outputEventCount",
    ])

    private static let knownOperator: Gen<String> = Gen<String>.fromElements(of: [
        "$eq", "$ne", "$gt", "$gte", "$lt", "$lte",
    ])

    /// Arbitrary match-key generator: mixes known keys with random strings
    /// so the unknown-key path gets exercised too.
    private static let anyMatchKey: Gen<String> = Gen<String>.one(of: [
        knownMatchKey,
        String.arbitrary.suchThat { !$0.isEmpty && !$0.hasPrefix("$") },
    ])

    /// Arbitrary operator: mixes known operators with bogus ones.
    private static let anyOperator: Gen<String> = Gen<String>.one(of: [
        knownOperator,
        String.arbitrary.suchThat { $0.hasPrefix("$") && $0 != "$" },
    ])

    private static let scalar: Gen<Double> = Double.arbitrary.suchThat { $0.isFinite }

    // MARK: - Bare scalar (shorthand $eq)

    func testBareScalarNeverCrashes() {
        property("Bare scalar match value returns Bool for any key") <- forAll(
            Self.anyMatchKey,
            Self.scalar
        ) { (key: String, value: Double) in
            let expr = MatchExpression(conditions: [key: .scalar(value)])
            // Evaluate — must not throw, must not crash. The return value
            // is the invariant we're guarding: a Bool, either true or false.
            let result = self.context.evaluateMatch(expr)
            return result == true || result == false
        }
    }

    // MARK: - Single operator

    func testSingleOperatorNeverCrashes() {
        property("Any (key, operator, value) triple returns Bool") <- forAll(
            Self.anyMatchKey,
            Self.anyOperator,
            Self.scalar
        ) { (key: String, op: String, value: Double) in
            let expr = MatchExpression(conditions: [key: .operators([op: value])])
            let result = self.context.evaluateMatch(expr)
            return result == true || result == false
        }
    }

    // MARK: - Multi-operator AND (same key)

    func testMultiOperatorAndNeverCrashes() {
        property("Multiple operators under one key evaluate via AND") <- forAll(
            Self.anyMatchKey,
            Self.knownOperator,
            Self.knownOperator,
            Self.scalar,
            Self.scalar
        ) { (key: String, opA: String, opB: String, vA: Double, vB: Double) in
            // Distinct operators required — dict dedupes same-key writes.
            let ops: [String: Double]
            if opA != opB {
                ops = [opA: vA, opB: vB]
            } else {
                ops = [opA: vA]
            }
            let expr = MatchExpression(conditions: [key: .operators(ops)])
            let result = self.context.evaluateMatch(expr)
            return result == true || result == false
        }
    }

    // MARK: - Multi-key AND

    func testMultiKeyAndNeverCrashes() {
        property("Multi-key matches evaluate via AND without crashing") <- forAll(
            Self.anyMatchKey,
            Self.anyMatchKey,
            Self.scalar,
            Self.scalar
        ) { (kA: String, kB: String, vA: Double, vB: Double) in
            let conditions: [String: MatchValue]
            if kA != kB {
                conditions = [kA: .scalar(vA), kB: .scalar(vB)]
            } else {
                conditions = [kA: .scalar(vA)]
            }
            let expr = MatchExpression(conditions: conditions)
            let result = self.context.evaluateMatch(expr)
            return result == true || result == false
        }
    }

    // MARK: - timeSince

    func testTimeSinceNeverCrashes() {
        // timeSince values are nested dicts keyed by timestamp uniform name.
        // Include one known name ("iTimeAgentStateChange") and one random
        // string so the unknown-timestamp path gets exercised.
        let knownUniform = Gen<String>.fromElements(of: [
            "iTimeAgentStateChange", "iTimeLastOutput", "iTimeLastNotification",
            "iTimeCommandStart", "iTimeCommandEnd",
        ])
        let unknownUniform = String.arbitrary.suchThat { !$0.isEmpty && !$0.hasPrefix("iTime") }
        let uniformName = Gen<String>.one(of: [knownUniform, unknownUniform])

        property("timeSince expressions never crash") <- forAll(
            uniformName,
            Self.knownOperator,
            Self.scalar
        ) { (name: String, op: String, value: Double) in
            let nested: [String: MatchValue] = [name: .operators([op: value])]
            let expr = MatchExpression(conditions: ["timeSince": .timeSince(nested)])
            let result = self.context.evaluateMatch(expr)
            return result == true || result == false
        }
    }

    // MARK: - Empty conditions (degenerate case)

    func testEmptyConditionsReturnsTrue() {
        // Empty AND is vacuously true — spec-level contract. No forAll
        // here; just one assertion that the degenerate case is stable.
        let expr = MatchExpression(conditions: [:])
        XCTAssertTrue(context.evaluateMatch(expr))
    }
}
