import XCTest
@testable import Holoscape

/// Task 15.2 — density-mode transition latency.
///
/// Requirement 10.2 / 15.2: every `DensityModeManager.setMode` transition
/// completes in under 200ms end-to-end. "End-to-end" here means the
/// synchronous work the manager performs: mode swap, animation drain,
/// config write, notification post. Observers that subscribe to
/// `.densityModeDidChange` and do their own heavy work are out of scope —
/// that's their budget, not the manager's.
///
/// Headless. No window, no chrome views — the manager operates at the
/// service layer and has no AppKit surface to render.
@MainActor
final class DensityModeTransitionTests: XCTestCase {

    private final class StubWriter: DensityModeConfigWriter {
        func writeDensityMode(_ modeRawValue: String) {}
    }

    /// The full cycle exercised by this test.
    private static let cycle: [DensityModeManager.Mode] = [
        .full, .minimal, .off, .full,
    ]

    /// Hard upper bound per the spec. 200ms is the user-perceptible
    /// threshold below which a state change feels "instant."
    private static let budgetSeconds: TimeInterval = 0.200

    func testCycleTransitionsUnderBudget() {
        let writer = StubWriter()
        let engine = AnimationEngine()
        let manager = DensityModeManager(
            initialMode: .full,
            configWriter: writer,
            animationEngine: engine
        )

        // Pre-seed a few queued animations so at least one transition
        // has to exercise the `suppressAll` drain path (otherwise the
        // full→minimal step is essentially a free no-op at the engine
        // level). This keeps the measurement honest.
        seedAnimations(on: engine, count: 6)

        for next in Self.cycle.dropFirst() {
            let elapsed = measureTransition(manager: manager, to: next)
            XCTAssertLessThan(elapsed, Self.budgetSeconds,
                              "\(manager.mode) → \(next) took \(elapsed * 1000)ms; budget is \(Self.budgetSeconds * 1000)ms")
        }
    }

    /// Stress variant: run the full cycle 20 times, assert every
    /// transition stays under budget. Catches a regression where the
    /// first transition is fine but subsequent ones stall (e.g. a
    /// growing notification-observer list).
    func testRepeatedCycleStaysUnderBudget() {
        let manager = DensityModeManager(
            initialMode: .full,
            configWriter: StubWriter(),
            animationEngine: AnimationEngine()
        )

        for iteration in 0..<20 {
            for next in Self.cycle.dropFirst() {
                let elapsed = measureTransition(manager: manager, to: next)
                XCTAssertLessThan(elapsed, Self.budgetSeconds,
                                  "Iteration \(iteration): \(manager.mode) → \(next) took \(elapsed * 1000)ms")
            }
        }
    }

    // MARK: - Helpers

    private func measureTransition(
        manager: DensityModeManager,
        to newMode: DensityModeManager.Mode
    ) -> TimeInterval {
        let start = CACurrentMediaTime()
        manager.setMode(newMode)
        let end = CACurrentMediaTime()
        return end - start
    }

    private func seedAnimations(on engine: AnimationEngine, count: Int) {
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
        let keys: [SurfaceKey] = [
            .tabBarContainer, .sidebarContainer, .inputBoxContainer,
            .sessionLauncherContainer, .splitPaneDivider, .sidebarRowNormal,
        ]
        for i in 0..<count {
            let layer = CALayer()
            engine.animateSurface(keys[i % keys.count], to: resolved, on: layer, with: anim)
        }
    }
}
