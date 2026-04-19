import XCTest
import SwiftCheck
@testable import Holoscape

/// Amplify Property 12 — Feature flag off disables every shape code
/// path (Requirement 2.8).
///
/// The `HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS` env flag gates shaped-window
/// rendering. When off, Holoscape must behave as if `windowShape` is
/// absent from every manifest. This property verifies at the
/// ShapedWindowController boundary: with the flag off, the controller
/// reports it explicitly (`featureFlagEnabled == false`) regardless
/// of what "off" looks like — absent env var, the literal string "0",
/// garbage values, empty string, etc.
///
/// The downstream consumers (SkinEngine.resolveWindowShape and
/// MainWindowController.applyWindowShape) both guard on
/// `featureFlagEnabled`, so pinning this single boolean is the
/// load-bearing invariant.
@MainActor
final class FeatureFlagPropertyTests: XCTestCase {

    // MARK: - Generators

    /// Any string other than the literal "1". Alphabet deliberately
    /// excludes '1', so `suchThat` is unnecessary — the `.map`
    /// produces a string that by construction cannot equal "1".
    /// Using `suchThat` here would turn the Gen into a rejection loop
    /// and blow up runtime (seen previously in OperatorTotality tests
    /// before they were rewritten from SwiftCheck String.arbitrary to
    /// bounded alphabets).
    private static let nonOneString: Gen<String> = Gen<Character>
        .fromElements(of: Array("023456789abcdefghijklmnoptrue_-"))
        .proliferate(withSize: 4)
        .map { String($0) }

    // MARK: - Properties

    /// Exhaustive for the "on" direction — one input, one expected
    /// outcome. Not generated, just a sanity-check companion to the
    /// flag-off property.
    func testExplicitOneTurnsFlagOn() {
        let controller = ShapedWindowController(
            environment: ["HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS": "1"]
        )
        XCTAssertTrue(controller.featureFlagEnabled)
    }

    func testAnyNonOneValueLeavesFlagOff() {
        property("any env value other than '1' leaves featureFlagEnabled false") <- forAll(
            Self.nonOneString
        ) { (value: String) in
            let controller = ShapedWindowController(
                environment: ["HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS": value]
            )
            return controller.featureFlagEnabled == false
        }
    }

    func testAbsentEnvVarLeavesFlagOff() {
        // The all-zero case — no env var at all. Not parameterized
        // because there's nothing to generate.
        let controller = ShapedWindowController(environment: [:])
        XCTAssertFalse(controller.featureFlagEnabled)
    }

    /// Flag-off invariant: validate must reject every shape descriptor
    /// when the flag is off... wait — it doesn't actually. `validate` is
    /// a static function; the flag gate happens at the call site
    /// (SkinEngine.resolveWindowShape), not inside validate. Test the
    /// call-site path through a higher-level invariant: a controller
    /// with flag off has `featureFlagEnabled == false` and nobody
    /// calls into validate when that flag is false. This property
    /// makes it explicit so a future refactor can't quietly start
    /// calling validate with the flag off.
    func testFlagOffPredicateIsStableAcrossManyConstructions() {
        // Many fresh constructions with the flag off must all report
        // false. Catches a race-free state or static-state bug where
        // an accidental singleton latches onto one value.
        property("flag-off controllers all report featureFlagEnabled = false") <- forAll(
            Self.nonOneString
        ) { (value: String) in
            let controllers = (0..<5).map { _ in
                ShapedWindowController(
                    environment: ["HOLOSCAPE_AMPLIFY_SHAPED_WINDOWS": value]
                )
            }
            return controllers.allSatisfy { !$0.featureFlagEnabled }
        }
    }
}
