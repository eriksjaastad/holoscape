import XCTest
import AppKit
import QuartzCore
@testable import Holoscape

/// Task 5.4 — AnimationEngine lifecycle:
/// - Display link starts when first animation queued (when hostView present).
/// - Active animations drain on completion; display link stops.
/// - suppressAll() immediately applies final state.
/// - Missing curves apply values instantly, no animation added.
@MainActor
final class AnimationEngineTests: XCTestCase {

    // MARK: - Helpers

    private func makeCurve(duration: CFTimeInterval = 0.2) -> SkinContext.ResolvedCurve {
        SkinContext.ResolvedCurve(duration: duration, timingFunction: .easeInEaseOut, isSpring: false)
    }

    private func makeSpringCurve(duration: CFTimeInterval = 0.4) -> SkinContext.ResolvedCurve {
        SkinContext.ResolvedCurve(duration: duration, timingFunction: .default, isSpring: true)
    }

    private func makeResolved(
        fillColor: NSColor = .red,
        corner: CGFloat = 8,
        borderColor: NSColor? = nil,
        borderWidth: CGFloat = 0,
        animation: SkinContext.ResolvedAnimation? = nil
    ) -> SkinContext.ResolvedSurface {
        let border = borderColor.map { SkinContext.ResolvedBorder(color: $0, width: borderWidth) }
        return SkinContext.ResolvedSurface(
            fill: .color(fillColor),
            border: border,
            corner: .uniform(corner),
            padding: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
            shadow: nil,
            font: nil,
            text: SkinContext.ResolvedText(color: .white, shadow: nil),
            animation: animation,
            states: []
        )
    }

    // MARK: - Instant application (no curve)

    func testAnimateSurfaceWithoutCurveAppliesInstantly() {
        let engine = AnimationEngine()
        let layer = CALayer()
        let resolved = makeResolved(fillColor: .green, corner: 12)

        engine.animateSurface(.tabBarContainer, to: resolved, on: layer, with: nil)

        // Model values applied directly; nothing queued.
        XCTAssertEqual(layer.cornerRadius, 12)
        XCTAssertTrue(engine.activeAnimations.isEmpty)
        XCTAssertNil(engine.displayLink, "No display link when nothing animates")
    }

    func testAnimateSurfaceWithEmptyAnimationDescriptorAppliesInstantly() {
        let engine = AnimationEngine()
        let layer = CALayer()
        let empty = SkinContext.ResolvedAnimation(default: nil, fill: nil, corner: nil)
        let resolved = makeResolved(fillColor: .blue, corner: 4, animation: empty)

        engine.animateSurface(.tabBarContainer, to: resolved, on: layer, with: empty)

        XCTAssertEqual(layer.cornerRadius, 4)
        XCTAssertTrue(engine.activeAnimations.isEmpty)
    }

    // MARK: - Animation queuing

    func testAnimateSurfaceWithCurveQueuesAnimation() {
        let engine = AnimationEngine()
        let layer = CALayer()
        let curve = makeCurve()
        let anim = SkinContext.ResolvedAnimation(default: curve, fill: nil, corner: nil)
        let resolved = makeResolved(fillColor: .red, corner: 10, animation: anim)

        engine.animateSurface(.tabBarContainer, to: resolved, on: layer, with: anim)

        XCTAssertFalse(engine.activeAnimations.isEmpty,
                       "Active animations populated when curve supplied")
        XCTAssertNotNil(layer.animation(forKey: "fill"),
                        "fill animation added to layer under property-rawValue key")
        XCTAssertNotNil(layer.animation(forKey: "corner"),
                        "corner animation added when default curve covers it")
        // Model values are set so final state persists after animation.
        XCTAssertEqual(layer.cornerRadius, 10)
    }

    func testPerPropertyCurvesOverrideDefault() {
        let engine = AnimationEngine()
        let layer = CALayer()
        let fastCorner = SkinContext.ResolvedCurve(duration: 0.15, timingFunction: .linear, isSpring: false)
        let slowFill = SkinContext.ResolvedCurve(duration: 0.35, timingFunction: .easeOut, isSpring: false)
        let anim = SkinContext.ResolvedAnimation(default: nil, fill: slowFill, corner: fastCorner)
        let resolved = makeResolved(animation: anim)

        engine.animateSurface(.tabBarContainer, to: resolved, on: layer, with: anim)

        let fillAnim = layer.animation(forKey: "fill") as? CABasicAnimation
        let cornerAnim = layer.animation(forKey: "corner") as? CABasicAnimation
        XCTAssertEqual(fillAnim?.duration ?? 0, 0.35, accuracy: 0.001)
        XCTAssertEqual(cornerAnim?.duration ?? 0, 0.15, accuracy: 0.001)
    }

    func testSpringCurveCreatesCASpringAnimation() {
        let engine = AnimationEngine()
        let layer = CALayer()
        let spring = makeSpringCurve()
        let anim = SkinContext.ResolvedAnimation(default: spring, fill: nil, corner: nil)
        let resolved = makeResolved(animation: anim)

        engine.animateSurface(.tabBarContainer, to: resolved, on: layer, with: anim)

        XCTAssertTrue(layer.animation(forKey: "fill") is CASpringAnimation,
                      "Spring curves produce CASpringAnimation, not CABasicAnimation")
    }

    // MARK: - Border animation

    func testBorderAnimatesWhenTargetHasBorder() {
        let engine = AnimationEngine()
        let layer = CALayer()
        layer.borderColor = NSColor.red.cgColor
        layer.borderWidth = 1
        let curve = makeCurve()
        let anim = SkinContext.ResolvedAnimation(default: curve, fill: nil, corner: nil)
        let resolved = makeResolved(borderColor: .yellow, borderWidth: 2, animation: anim)

        engine.animateSurface(.tabBarContainer, to: resolved, on: layer, with: anim)

        XCTAssertNotNil(layer.animation(forKey: "borderWidth"),
                        "borderWidth animation queued when curve + target border present")
        XCTAssertNotNil(layer.animation(forKey: "borderColor"),
                        "borderColor requires its own animation — implicit grouping doesn't exist")
        XCTAssertEqual(layer.borderWidth, 2)
    }

    func testBorderFadesOutWhenTargetHasNoBorderButLayerDid() {
        let engine = AnimationEngine()
        let layer = CALayer()
        layer.borderWidth = 4
        let curve = makeCurve()
        let anim = SkinContext.ResolvedAnimation(default: curve, fill: nil, corner: nil)
        let resolved = makeResolved(borderColor: nil, animation: anim)

        engine.animateSurface(.tabBarContainer, to: resolved, on: layer, with: anim)

        XCTAssertNotNil(layer.animation(forKey: "borderWidth"),
                        "borderWidth animation queued to fade to zero")
        XCTAssertEqual(layer.borderWidth, 0)
    }

    // MARK: - Suppress all

    func testSuppressAllRemovesEveryActiveAnimation() {
        let engine = AnimationEngine()
        let layer1 = CALayer()
        let layer2 = CALayer()
        let anim = SkinContext.ResolvedAnimation(default: makeCurve(duration: 1.0), fill: nil, corner: nil)
        let resolved = makeResolved(animation: anim)

        engine.animateSurface(.tabBarContainer, to: resolved, on: layer1, with: anim)
        engine.animateSurface(.sidebarContainer, to: resolved, on: layer2, with: anim)
        XCTAssertFalse(engine.activeAnimations.isEmpty)

        engine.suppressAll()

        XCTAssertTrue(engine.activeAnimations.isEmpty,
                      "Active animations cleared after suppressAll")
        // Both fill AND corner were queued by the default curve — verify every
        // property was stripped, not just fill. A regression that suppressed
        // only one property would otherwise slip through.
        XCTAssertNil(layer1.animation(forKey: "fill"), "layer1 fill stripped")
        XCTAssertNil(layer1.animation(forKey: "corner"), "layer1 corner stripped")
        XCTAssertNil(layer2.animation(forKey: "fill"), "layer2 fill stripped")
        XCTAssertNil(layer2.animation(forKey: "corner"), "layer2 corner stripped")
    }

    func testSuppressAllStopsDisplayLink() {
        let engine = AnimationEngine()
        let layer = CALayer()
        let anim = SkinContext.ResolvedAnimation(default: makeCurve(), fill: nil, corner: nil)
        let resolved = makeResolved(animation: anim)

        engine.animateSurface(.tabBarContainer, to: resolved, on: layer, with: anim)
        engine.suppressAll()

        XCTAssertNil(engine.displayLink, "displayLink is nil after suppressAll drains active set")
    }

    // MARK: - Display link lifecycle (hostView-backed)

    /// Building an in-memory NSView with an attached NSWindow gives
    /// `NSView.displayLink` a real screen to back against, so the engine's
    /// full lifecycle — create on active, invalidate on idle — is exercised.
    func testDisplayLinkStartsAndStopsWithHostView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSView(frame: window.contentView!.bounds)
        host.wantsLayer = true
        window.contentView!.addSubview(host)

        let engine = AnimationEngine(hostView: host)
        let layer = CALayer()
        let anim = SkinContext.ResolvedAnimation(default: makeCurve(duration: 0.05), fill: nil, corner: nil)
        let resolved = makeResolved(animation: anim)

        engine.animateSurface(.tabBarContainer, to: resolved, on: layer, with: anim)
        XCTAssertNotNil(engine.displayLink,
                        "Display link created when first animation queued and host view present")

        // Synchronously suppress to deterministically drain the active set;
        // waiting for real CAAnimationDelegate callbacks is flaky in tests.
        engine.suppressAll()
        XCTAssertNil(engine.displayLink,
                     "Display link stops when active set drains to empty")
    }

    // MARK: - Animation ID uniqueness

    func testConcurrentFillAndCornerShareSurfaceKey() {
        let engine = AnimationEngine()
        let layer = CALayer()
        let anim = SkinContext.ResolvedAnimation(default: makeCurve(), fill: nil, corner: nil)
        let resolved = makeResolved(animation: anim)

        engine.animateSurface(.tabBarContainer, to: resolved, on: layer, with: anim)

        let fillID = AnimationEngine.AnimationID(surfaceKey: .tabBarContainer, property: .fill)
        let cornerID = AnimationEngine.AnimationID(surfaceKey: .tabBarContainer, property: .corner)
        XCTAssertNotNil(engine.activeAnimations[fillID], "fill animation tracked under its own ID")
        XCTAssertNotNil(engine.activeAnimations[cornerID], "corner animation tracked under its own ID")
    }

    // MARK: - Re-queue / cancellation races

    /// Re-entering animateSurface for the same surface/property while the
    /// prior animation is still in flight must not leave the old delegate
    /// able to drain the new tracking entry. The token check in
    /// animationDidComplete protects against this — the old animation's
    /// callback sees a different token and becomes a no-op.
    func testReQueueWhileInFlightKeepsLatestTrackingEntry() {
        let engine = AnimationEngine()
        let layer = CALayer()
        let slow = SkinContext.ResolvedCurve(duration: 1.0, timingFunction: .linear, isSpring: false)
        let anim = SkinContext.ResolvedAnimation(default: slow, fill: nil, corner: nil)
        let resolved = makeResolved(fillColor: .red, animation: anim)

        engine.animateSurface(.tabBarContainer, to: resolved, on: layer, with: anim)
        let fillID = AnimationEngine.AnimationID(surfaceKey: .tabBarContainer, property: .fill)
        let firstToken = engine.activeAnimations[fillID]?.token
        XCTAssertNotNil(firstToken)

        // Re-queue — this replaces the layer's "fill" animation. Core
        // Animation cancels the first with finished=false and fires its
        // delegate asynchronously (after this call returns).
        let resolved2 = makeResolved(fillColor: .blue, animation: anim)
        engine.animateSurface(.tabBarContainer, to: resolved2, on: layer, with: anim)
        let secondToken = engine.activeAnimations[fillID]?.token
        XCTAssertNotNil(secondToken)
        XCTAssertNotEqual(firstToken, secondToken,
                          "Re-queue must mint a new token, not reuse the first")
        XCTAssertNotNil(layer.animation(forKey: "fill"),
                        "Second animation is active on the layer")
    }

    /// The token-mismatch check in animationDidComplete protects the successor
    /// from being drained by a cancelled predecessor's stale callback. We
    /// exercise the pure invariant directly — CAAnimation delivery timing on
    /// a non-rendered layer is implementation-defined, so driving the real
    /// delegate chain would produce a flaky test.
    func testStaleTokenCompletionDoesNotDrainCurrentEntry() {
        let engine = AnimationEngine()
        let layer = CALayer()
        let slow = SkinContext.ResolvedCurve(duration: 1.0, timingFunction: .linear, isSpring: false)
        let anim = SkinContext.ResolvedAnimation(default: slow, fill: nil, corner: nil)

        engine.animateSurface(.tabBarContainer, to: makeResolved(fillColor: .red, animation: anim),
                              on: layer, with: anim)
        engine.animateSurface(.tabBarContainer, to: makeResolved(fillColor: .blue, animation: anim),
                              on: layer, with: anim)

        let fillID = AnimationEngine.AnimationID(surfaceKey: .tabBarContainer, property: .fill)
        let successorToken = engine.activeAnimations[fillID]?.token
        XCTAssertNotNil(successorToken)

        // Simulate the cancelled predecessor's delegate firing late with its
        // stale token (any value other than the current one).
        let staleToken: UInt64 = (successorToken ?? 1) &- 1
        engine.animationDidComplete(id: fillID, token: staleToken, finished: false)

        XCTAssertEqual(engine.activeAnimations[fillID]?.token, successorToken,
                       "Stale-token callback must not drain the current tracking entry")
    }

    /// Conversely, a completion callback carrying the CURRENT token must
    /// drain the entry — that's how normal animation completion works.
    func testCurrentTokenCompletionDrainsEntry() {
        let engine = AnimationEngine()
        let layer = CALayer()
        let anim = SkinContext.ResolvedAnimation(default: makeCurve(), fill: nil, corner: nil)
        engine.animateSurface(.tabBarContainer, to: makeResolved(animation: anim),
                              on: layer, with: anim)
        let fillID = AnimationEngine.AnimationID(surfaceKey: .tabBarContainer, property: .fill)
        let token = engine.activeAnimations[fillID]?.token
        XCTAssertNotNil(token)

        engine.animationDidComplete(id: fillID, token: token!, finished: true)
        XCTAssertNil(engine.activeAnimations[fillID],
                     "Current-token completion drains normally")
    }
}
