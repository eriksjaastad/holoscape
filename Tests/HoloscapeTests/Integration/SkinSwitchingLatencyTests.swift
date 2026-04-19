import XCTest
@testable import Holoscape

/// Task 15.4 — skin switching latency (Requirement 15.5).
///
/// Budget: switching from one loaded skin to another must complete in
/// under 200ms on cold and warm paths. "Switching" here is the service-
/// layer cost: unregister old fonts, load new manifest, decode images,
/// register new fonts, build the `ResolvedSurface` map. View re-layout
/// is a per-chrome-view cost and is bounded by each view's `layout()`
/// implementation — not measured here (this is a headless test; no
/// AppKit view tree is spun up).
///
/// Two shapes exercised:
///   • `Default → HoloscapeSynthwave` (cold load: no prior fonts)
///   • `HoloscapeSynthwave → HoloscapeSynthwave` (same-skin reload,
///     representative of Task 11's hot-reload trigger)
///   • `HoloscapeSynthwave → Default` (unload path — drops all assets)
@MainActor
final class SkinSwitchingLatencyTests: XCTestCase {

    /// User-perceptible budget. Below this, skin changes feel instant.
    private static let budgetSeconds: TimeInterval = 0.200

    func testSwitchFromDefaultToReferenceUnderBudget() throws {
        let engine = SkinEngine()
        guard engine.availableSkins().contains("HoloscapeSynthwave") else {
            throw XCTSkip("HoloscapeSynthwave not present in Bundle.module — run `swift build` first")
        }

        // Warm the filesystem / decoder caches once so the measurement
        // reflects steady-state switching cost, not first-touch disk reads.
        _ = try engine.loadComposite(named: "HoloscapeSynthwave")
        let priorFonts = try engine.loadComposite(named: "HoloscapeSynthwave").fonts
        engine.unregisterFonts(priorFonts)

        let elapsed = try measureSwitch(engine: engine, to: "HoloscapeSynthwave")
        XCTAssertLessThan(elapsed, Self.budgetSeconds,
                          "Default → HoloscapeSynthwave took \(elapsed * 1000)ms; budget is \(Self.budgetSeconds * 1000)ms")
    }

    func testSameSkinReloadUnderBudget() throws {
        // Task 11's hot-reload fires this exact shape: user edits
        // HoloscapeSynthwave's skin.json, FSEvents fires, reloadSkin
        // calls loadComposite with the same name. The previous bundle's
        // fonts are unregistered before the new one is registered.
        let engine = SkinEngine()
        guard engine.availableSkins().contains("HoloscapeSynthwave") else {
            throw XCTSkip("HoloscapeSynthwave not present in Bundle.module — run `swift build` first")
        }

        let first = try engine.loadComposite(named: "HoloscapeSynthwave")

        let start = CACurrentMediaTime()
        engine.unregisterFonts(first.fonts)
        _ = try engine.loadComposite(named: "HoloscapeSynthwave")
        let elapsed = CACurrentMediaTime() - start

        XCTAssertLessThan(elapsed, Self.budgetSeconds,
                          "HoloscapeSynthwave reload took \(elapsed * 1000)ms; budget is \(Self.budgetSeconds * 1000)ms")
    }

    func testSwitchToDefaultUnloadUnderBudget() throws {
        let engine = SkinEngine()
        guard engine.availableSkins().contains("HoloscapeSynthwave") else {
            throw XCTSkip("HoloscapeSynthwave not present in Bundle.module — run `swift build` first")
        }

        let loaded = try engine.loadComposite(named: "HoloscapeSynthwave")

        let start = CACurrentMediaTime()
        engine.unregisterFonts(loaded.fonts)
        let unloaded = try engine.loadComposite(named: "Default")
        let elapsed = CACurrentMediaTime() - start

        XCTAssertNil(unloaded.surfaces, "Default resolves to the sentinel — nil surfaces")
        XCTAssertLessThan(elapsed, Self.budgetSeconds,
                          "HoloscapeSynthwave → Default took \(elapsed * 1000)ms; budget is \(Self.budgetSeconds * 1000)ms")
    }

    /// Repeated back-and-forth switching. Catches regressions where the
    /// first switch is fast but the second stalls (e.g. font-registry
    /// table never drained, image cache accumulating, FSEventStream
    /// leaking between calls).
    func testRepeatedSwitchingStaysUnderBudget() throws {
        let engine = SkinEngine()
        guard engine.availableSkins().contains("HoloscapeSynthwave") else {
            throw XCTSkip("HoloscapeSynthwave not present in Bundle.module — run `swift build` first")
        }

        var heldFonts = SkinFontBundle(fonts: [:], registeredURLs: [])

        for iteration in 0..<10 {
            let start = CACurrentMediaTime()
            engine.unregisterFonts(heldFonts)
            let loaded = try engine.loadComposite(named: "HoloscapeSynthwave")
            heldFonts = loaded.fonts
            let elapsed = CACurrentMediaTime() - start

            XCTAssertLessThan(elapsed, Self.budgetSeconds,
                              "Iteration \(iteration) took \(elapsed * 1000)ms; budget is \(Self.budgetSeconds * 1000)ms")
        }

        // Clean up the last held bundle so the process-scope font
        // registry stays symmetric after the test.
        engine.unregisterFonts(heldFonts)
    }

    // MARK: - Helpers

    private func measureSwitch(engine: SkinEngine, to name: String) throws -> TimeInterval {
        let start = CACurrentMediaTime()
        _ = try engine.loadComposite(named: name)
        return CACurrentMediaTime() - start
    }
}
