import XCTest
import AppKit
import QuartzCore
import SwiftCheck
@testable import Holoscape

/// Property 16 — No animation suppression leakage (Requirements 13.5, 13.1, 13.2, 13.4).
///
/// When the user drops density mode from Full → Minimal (or Off), any
/// in-flight animations are suppressed via `AnimationEngine.suppressAll`.
/// When they later return to Full mode, those suppressed animations must
/// NOT replay — mode returning to Full doesn't mean "re-queue every state
/// change that happened while we were animating-off." Fresh animations
/// only fire on subsequent state transitions.
///
/// Property: after any `[Full → (Minimal|Off) → Full]` transition sequence,
/// with arbitrary numbers of animations queued in each phase,
/// `engine.activeAnimations` contains only animations queued AFTER returning
/// to Full. None of the suppressed-during-Minimal animations leak back.
@MainActor
final class AnimationSuppressionLeakagePropertyTests: XCTestCase {

    private final class StubDensityWriter: DensityModeConfigWriter {
        func writeDensityMode(_ modeRawValue: String) {}
    }

    // MARK: - Generators

    private static let countGen: Gen<Int> =
        Gen<Int>.fromElements(of: [0, 1, 2, 3, 5])

    /// Int discriminator for non-full modes — 0 = .minimal, 1 = .off.
    /// SwiftCheck's Arbitrary constraint means we can't pass `Gen<Mode>`
    /// directly unless Mode conforms to Arbitrary; going through Int
    /// avoids the conformance while keeping the generator declarative.
    private static let nonFullModeDiscriminator: Gen<Int> =
        Gen<Int>.fromElements(of: [0, 1])

    private static func mode(from discriminator: Int) -> DensityModeManager.Mode {
        discriminator == 0 ? .minimal : .off
    }

    // MARK: - Helpers

    private func makeCurve(duration: CFTimeInterval = 1.0) -> SkinContext.ResolvedCurve {
        SkinContext.ResolvedCurve(duration: duration, timingFunction: .easeInEaseOut, isSpring: false)
    }

    private func makeResolved(_ anim: SkinContext.ResolvedAnimation) -> SkinContext.ResolvedSurface {
        SkinContext.ResolvedSurface(
            fill: .color(.red),
            border: nil,
            corner: .uniform(8),
            padding: NSEdgeInsets(),
            shadow: nil,
            font: nil,
            text: SkinContext.ResolvedText(color: .white, shadow: nil),
            animation: anim,
            states: []
        )
    }

    // MARK: - Core property

    func testFullToNonFullToFullDoesNotReplay() {
        property("Full → (Minimal|Off) → Full never replays suppressed animations") <- forAll(
            Self.countGen,
            Self.nonFullModeDiscriminator,
            Self.countGen
        ) { (fullPhaseCount: Int, middleDisc: Int, returnPhaseCount: Int) in
            let middleMode = Self.mode(from: middleDisc)
            let density = DensityModeManager(initialMode: .full, configWriter: StubDensityWriter())
            let engine = AnimationEngine(densityModeManager: density)
            density.animationEngine = engine

            let layer = CALayer()
            let anim = SkinContext.ResolvedAnimation(default: self.makeCurve(), fill: nil, corner: nil)
            let resolved = self.makeResolved(anim)

            // Phase 1: Full mode — queue animations normally.
            for _ in 0..<fullPhaseCount {
                engine.animateSurface(.tabBarContainer, to: resolved, on: layer, with: anim)
            }

            // Transition to non-full — suppressAll fires as a side effect.
            density.setMode(middleMode)

            // Post-transition invariant: active set drained, link nil.
            if !engine.activeAnimations.isEmpty { return false }
            if engine.displayLink != nil { return false }

            // Phase 2: still in non-full — animateSurface takes the
            // instant-application branch because shouldAnimate() == false.
            // Queue attempts must NOT populate activeAnimations.
            for _ in 0..<fullPhaseCount {
                engine.animateSurface(.sidebarContainer, to: resolved, on: layer, with: anim)
            }
            if !engine.activeAnimations.isEmpty { return false }

            // Transition back to Full. This is the critical moment:
            // suppressed animations from Phase 1 must stay suppressed;
            // returning to Full does NOT re-queue them.
            density.setMode(.full)
            if !engine.activeAnimations.isEmpty {
                // Leakage! Something from Phase 1 or Phase 2 came back.
                return false
            }

            // Phase 3: Full — fresh animations DO queue.
            for _ in 0..<returnPhaseCount {
                engine.animateSurface(.inputBoxContainer, to: resolved, on: layer, with: anim)
            }
            // Leakage check: every surviving entry must come from Phase 3
            // (`.inputBoxContainer`). Any `.tabBarContainer` or
            // `.sidebarContainer` entry would mean an earlier phase leaked
            // through — which is the invariant this test guards.
            //
            // Count is NOT a stable assertion: repeated animateSurface calls
            // with the same (surfaceKey, property) on the same layer
            // OVERWRITE their activeAnimations slot (AnimationID is Hashable
            // and the key is identical). So 5 calls on one surface yield
            // 2 entries (fill + corner), not 10.
            for id in engine.activeAnimations.keys where id.surfaceKey != .inputBoxContainer {
                return false
            }
            if returnPhaseCount == 0 {
                return engine.activeAnimations.isEmpty
            }
            // At least the fill/corner entries for the Phase 3 surface
            // must be present — proves Phase 3 did queue something, so
            // the test isn't trivially true.
            return !engine.activeAnimations.isEmpty
        }
    }

    // MARK: - Middle-phase supression is total

    func testNonFullModeNeverPopulatesActiveAnimations() {
        // Regardless of how many animations we try to queue while in
        // Minimal or Off, the active set stays empty. Catches a future
        // bug where only the first queued animation is short-circuited.
        property("Queueing during Minimal/Off never populates the active set") <- forAll(
            Self.nonFullModeDiscriminator,
            Self.countGen
        ) { (modeDisc: Int, count: Int) in
            let mode = Self.mode(from: modeDisc)
            let density = DensityModeManager(initialMode: mode, configWriter: StubDensityWriter())
            let engine = AnimationEngine(densityModeManager: density)
            let layer = CALayer()
            let anim = SkinContext.ResolvedAnimation(default: self.makeCurve(), fill: nil, corner: nil)
            let resolved = self.makeResolved(anim)

            for _ in 0..<count {
                engine.animateSurface(.tabBarContainer, to: resolved, on: layer, with: anim)
            }
            return engine.activeAnimations.isEmpty
        }
    }
}
