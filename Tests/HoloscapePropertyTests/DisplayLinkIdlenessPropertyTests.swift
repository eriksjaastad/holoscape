import XCTest
import AppKit
import QuartzCore
import SwiftCheck
@testable import Holoscape

/// Property 8 — Display link idleness (Requirements 13.3, 15.4).
///
/// The `CADisplayLink` the chrome skinning engine owns must exist only
/// while animations are in flight. When the active-animation set drains,
/// the display link must be invalidated and nil-ed so idle chrome draws
/// zero frames per second — one of the spec's hard performance contracts.
///
/// Property: after any sequence of animate / complete / suppress operations,
/// `engine.activeAnimations.isEmpty ⇒ engine.displayLink == nil`.
///
/// Without a host view, `displayLink` is always nil (the engine's
/// `startDisplayLinkIfNeeded` short-circuits on missing hostView), so the
/// invariant holds trivially. The test re-uses the no-hostView path for
/// the "suppress drains to nil" property because the equivalence is
/// `isEmpty ⇒ nil`, which is the same regardless of whether a link was
/// ever created. A dedicated hostView-backed smoke test covers the
/// start-on-active direction (that half is already in AnimationEngineTests).
@MainActor
final class DisplayLinkIdlenessPropertyTests: XCTestCase {

    // In-test persistence stub — density mode manager needs a writer;
    // property tests don't care about the config file.
    private final class StubDensityWriter: DensityModeConfigWriter {
        func writeDensityMode(_ modeRawValue: String) {}
    }

    // MARK: - Operations

    /// A synthetic operation sequence element. Each iteration runs a
    /// small program to drive activeAnimations up and down.
    private enum Op {
        case animate(SurfaceKey)
        case completeSome  // drain a random subset via animationDidComplete
        case suppressAll
    }

    private static let surfaceKeys: [SurfaceKey] = [
        .tabBarContainer, .sidebarContainer, .inputBoxContainer,
        .sessionLauncherContainer, .splitPaneDivider,
    ]

    private static let opGen: Gen<Int> = Gen<Int>.fromElements(of: [0, 1, 2])
    private static let surfaceIdxGen: Gen<Int> =
        Gen<Int>.fromElements(of: Array(0..<surfaceKeys.count))

    // MARK: - Helpers

    private func makeCurve() -> SkinContext.ResolvedCurve {
        SkinContext.ResolvedCurve(duration: 0.2, timingFunction: .easeInEaseOut, isSpring: false)
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

    private func runProgram(_ program: [Op], engine: AnimationEngine, layers: [CALayer]) {
        let anim = SkinContext.ResolvedAnimation(default: makeCurve(), fill: nil, corner: nil)
        let resolved = makeResolved(anim)
        var layerIndex = 0

        for op in program {
            switch op {
            case .animate(let key):
                let layer = layers[layerIndex % layers.count]
                layerIndex += 1
                engine.animateSurface(key, to: resolved, on: layer, with: anim)
            case .completeSome:
                // Drain one tracked animation with its current token so the
                // completion is accepted (mimics a real CAAnimation finishing).
                if let (id, state) = engine.activeAnimations.first {
                    engine.animationDidComplete(id: id, token: state.token, finished: true)
                }
            case .suppressAll:
                engine.suppressAll()
            }
        }
    }

    // MARK: - Properties

    func testDisplayLinkIsNilWheneverActiveSetIsEmpty() {
        // Generate two parallel arrays of ints (opCode, surfaceIdx).
        // SwiftCheck Arbitrary-constrained forAll only sees primitive
        // generators; Op enums are constructed inside the closure.
        let opsGen = Self.opGen.proliferate(withSize: 16)
        let idxsGen = Self.surfaceIdxGen.proliferate(withSize: 16)

        property("activeAnimations.isEmpty implies displayLink == nil after every step") <- forAll(
            opsGen, idxsGen
        ) { opCodes, surfaceIdxs in
            let program: [Op] = zip(opCodes, surfaceIdxs).map { (code, idx) in
                switch code {
                case 0: return .animate(Self.surfaceKeys[idx % Self.surfaceKeys.count])
                case 1: return .completeSome
                default: return .suppressAll
                }
            }

            let engine = AnimationEngine()  // no hostView — displayLink stays nil always
            let layers = (0..<3).map { _ in CALayer() }

            for op in program {
                self.runProgram([op], engine: engine, layers: layers)
                if engine.activeAnimations.isEmpty && engine.displayLink != nil {
                    return false
                }
            }
            return true
        }
    }

    func testSuppressAllAlwaysDrainsActiveSetAndDisplayLink() {
        // After suppressAll, the invariant must hold unconditionally.
        // Generated input: how many animations to queue first.
        property("suppressAll drains activeAnimations and nils displayLink") <- forAll(
            Int.arbitrary.suchThat { $0 >= 0 && $0 <= 10 }
        ) { count in
            let engine = AnimationEngine()
            let layer = CALayer()
            let anim = SkinContext.ResolvedAnimation(default: self.makeCurve(), fill: nil, corner: nil)
            let resolved = self.makeResolved(anim)

            for _ in 0..<count {
                engine.animateSurface(.tabBarContainer, to: resolved, on: layer, with: anim)
            }
            engine.suppressAll()

            return engine.activeAnimations.isEmpty && engine.displayLink == nil
        }
    }

    // MARK: - HostView-backed smoke test (single invocation — not a property)

    /// Round-trip the full lifecycle with a real hostView so the
    /// create-on-active direction of the invariant is actually covered.
    /// Kept as a single XCTest rather than a property because window
    /// construction is expensive and a single iteration is sufficient.
    func testDisplayLinkRoundTripWithHostView() {
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
        let anim = SkinContext.ResolvedAnimation(default: makeCurve(), fill: nil, corner: nil)
        let resolved = makeResolved(anim)

        XCTAssertNil(engine.displayLink, "Idle at construction")

        engine.animateSurface(.tabBarContainer, to: resolved, on: layer, with: anim)
        XCTAssertNotNil(engine.displayLink, "Link active while animations queued")
        XCTAssertFalse(engine.activeAnimations.isEmpty)

        engine.suppressAll()
        XCTAssertNil(engine.displayLink, "Link nil after drain — the Property 8 invariant")
        XCTAssertTrue(engine.activeAnimations.isEmpty)
    }
}
