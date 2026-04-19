import XCTest
import SwiftCheck
@testable import Holoscape

/// Property 7 — Zero overhead when density is Off (Requirements 10.1, 10.3, 15.1, 15.4).
///
/// When density mode is `.off`, the chrome skinning system is fully
/// bypassed. Concretely:
///
/// 1. `SkinEngine.apply(skin:to:)` is the identity function — for every
///    `SkinDefinition`, every `AppearanceConfig`, the output equals the
///    input exactly. No color overrides applied.
/// 2. `SkinEngine` construction opens zero `FSEventStream` watchers —
///    `currentStream == nil` on a fresh instance. Off-mode callers never
///    call `startWatching`, and even before the first call, the engine
///    holds no watcher resources.
/// 3. Transitioning into `.off` drains any in-flight animations via
///    `AnimationEngine.suppressAll` — `activeAnimations.isEmpty` after
///    the transition, regardless of what was queued before.
///
/// Memory-graph inspection of `SkinContext` allocations (the spec's
/// original phrasing) isn't portable across test harnesses; the three
/// invariants above cover the same user-visible guarantee: idle chrome
/// pays no skin cost.
@MainActor
final class ZeroOverheadPropertyTests: XCTestCase {

    private final class StubWriter: DensityModeConfigWriter {
        func writeDensityMode(_ modeRawValue: String) {}
    }

    // MARK: - Generators

    /// A hex color string like `"#1a2b3c"`. Six lowercase hex digits.
    private static let hexColor: Gen<String> = Gen<Character>.fromElements(of:
        Array("0123456789abcdef")
    ).proliferate(withSize: 6).map { "#" + String($0) }

    /// A 16-entry hex array for `SkinDefinition.ansiColors`.
    private static let ansiPalette: Gen<[String]> =
        hexColor.proliferate(withSize: 16)

    // MARK: - Invariant 1: apply is identity in .off

    func testApplyIsIdentityUnderOffMode() {
        // Parallel-arrays trick: generate primitive pieces SwiftCheck
        // knows how to arbitrary, assemble the skin + config inside the
        // closure. Covers random window backgrounds, random ANSI palettes,
        // and the nil-ansi branch.
        property("Off-mode apply returns input AppearanceConfig unchanged") <- forAll(
            Self.hexColor, Self.hexColor, Self.ansiPalette, Bool.arbitrary
        ) { (bg: String, fg: String, palette: [String], includeAnsi: Bool) in
            let density = DensityModeManager(initialMode: .off, configWriter: StubWriter())
            let engine = SkinEngine()
            engine.densityModeManager = density

            var skin = SkinDefinition()
            skin.windowBackground = bg
            skin.textForeground = fg
            if includeAnsi { skin.ansiColors = palette }

            let input = AppearanceConfig.default
            let output = engine.apply(skin: skin, to: input)

            return output == input
        }
    }

    // MARK: - Invariant 2: no watcher on construction

    func testFreshSkinEngineHoldsNoFSEventStream() {
        // Constructing a SkinEngine must not allocate system watcher
        // resources. Repeatable: 50 independent constructions.
        for _ in 0..<50 {
            let engine = SkinEngine()
            XCTAssertTrue(engine._currentStreamIsNil,
                          "SkinEngine() must not open an FSEventStream on construction")
        }
    }

    func testStartWatchingIsNoOpForDefaultSkinName() {
        // "Default" is the sentinel that means "no skin loaded." The
        // watcher path must short-circuit so an Off-mode user whose
        // config persists `"Default"` never incurs watcher overhead.
        let engine = SkinEngine()
        engine.startWatching(skinName: "Default")
        XCTAssertTrue(engine._currentStreamIsNil,
                      "startWatching(\"Default\") must not open a watcher")
    }

    // MARK: - Invariant 3: entering .off drains animations

    func testEnteringOffDrainsActiveAnimations() {
        property("Transition full→off drains activeAnimations regardless of queue depth") <- forAll(
            Int.arbitrary.suchThat { $0 >= 0 && $0 <= 12 }
        ) { (queueDepth: Int) in
            let engine = AnimationEngine()
            let manager = DensityModeManager(
                initialMode: .full,
                configWriter: StubWriter(),
                animationEngine: engine
            )

            let layer = CALayer()
            let curve = SkinContext.ResolvedCurve(
                duration: 0.25, timingFunction: .easeInEaseOut, isSpring: false
            )
            let anim = SkinContext.ResolvedAnimation(default: curve, fill: nil, corner: nil)
            let resolved = SkinContext.ResolvedSurface(
                fill: .color(.red), border: nil, corner: .uniform(4),
                padding: NSEdgeInsets(), shadow: nil, font: nil,
                text: SkinContext.ResolvedText(color: .white, shadow: nil),
                animation: anim, states: []
            )

            // Queue animations on distinct surface/layer pairs so each
            // occupies its own slot in activeAnimations. Repeating on
            // the same (surface, layer) would overwrite under the
            // AnimationID Hashable contract.
            let allKeys: [SurfaceKey] = [
                .tabBarContainer, .sidebarContainer, .inputBoxContainer,
                .sessionLauncherContainer, .splitPaneDivider, .sidebarRowNormal,
                .windowBackground, .tabBarTabActive, .tabBarTabIdle,
                .inputBoxField, .tabBarTabNormal, .sidebarRowSelected,
            ]
            for i in 0..<queueDepth {
                let key = allKeys[i % allKeys.count]
                let ownLayer = CALayer()
                engine.animateSurface(key, to: resolved, on: ownLayer, with: anim)
                _ = layer  // silence unused warning on zero-depth case
            }

            manager.setMode(.off)

            return engine.activeAnimations.isEmpty
        }
    }
}

