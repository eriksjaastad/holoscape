import XCTest
@testable import Holoscape

/// Task 7.1 — DensityModeManager lifecycle + predicates + persistence.
///
/// These tests use a stub ConfigWriter and focus on the manager's
/// observable behavior: mode transitions, the three predicate queries,
/// notification posting, and persistence. Wiring to AnimationEngine's
/// suppressAll is covered by a minimal stub (the engine itself is
/// exercised in AnimationEngineTests).
@MainActor
final class DensityModeManagerTests: XCTestCase {

    // MARK: - Stubs

    /// Records every write so tests can assert round-trip correctness.
    final class StubWriter: DensityModeConfigWriter {
        var writes: [String] = []
        func writeDensityMode(_ modeRawValue: String) {
            writes.append(modeRawValue)
        }
    }

    // MARK: - Initial state

    func testInitialModeDefaultsToFull() {
        let writer = StubWriter()
        let manager = DensityModeManager(configWriter: writer)
        XCTAssertEqual(manager.mode, .full)
    }

    func testInitialModeIsRespectedFromInit() {
        let writer = StubWriter()
        let manager = DensityModeManager(initialMode: .minimal, configWriter: writer)
        XCTAssertEqual(manager.mode, .minimal)
    }

    // MARK: - Predicates per mode

    func testFullModePredicates() {
        let m = DensityModeManager(initialMode: .full, configWriter: StubWriter())
        XCTAssertTrue(m.isSkinActive())
        XCTAssertTrue(m.shouldRenderImages())
        XCTAssertTrue(m.shouldAnimate())
    }

    func testMinimalModePredicates() {
        let m = DensityModeManager(initialMode: .minimal, configWriter: StubWriter())
        XCTAssertTrue(m.isSkinActive(), "Skin is still active in minimal — just image-less")
        XCTAssertFalse(m.shouldRenderImages())
        XCTAssertFalse(m.shouldAnimate())
    }

    func testOffModePredicates() {
        let m = DensityModeManager(initialMode: .off, configWriter: StubWriter())
        XCTAssertFalse(m.isSkinActive(), "Skin engine must be bypassed entirely in off mode")
        XCTAssertFalse(m.shouldRenderImages())
        XCTAssertFalse(m.shouldAnimate())
    }

    // MARK: - Transitions

    func testSetModeToSameValueIsNoOp() {
        let writer = StubWriter()
        let manager = DensityModeManager(initialMode: .full, configWriter: writer)

        manager.setMode(.full)
        XCTAssertTrue(writer.writes.isEmpty,
                      "No-op transition should not persist")
    }

    func testSetModeUpdatesModeAndPersists() {
        let writer = StubWriter()
        let manager = DensityModeManager(initialMode: .full, configWriter: writer)

        manager.setMode(.minimal)

        XCTAssertEqual(manager.mode, .minimal)
        XCTAssertEqual(writer.writes, ["minimal"])
    }

    func testSetModePostsNotificationWithTransition() {
        let writer = StubWriter()
        let manager = DensityModeManager(initialMode: .full, configWriter: writer)

        let notified = expectation(forNotification: .densityModeDidChange, object: manager) { note in
            guard let info = note.userInfo else { return false }
            return (info["previous"] as? String) == "full"
                && (info["current"] as? String) == "off"
        }

        manager.setMode(.off)

        wait(for: [notified], timeout: 1.0)
    }

    func testMultipleTransitionsChainCorrectly() {
        let writer = StubWriter()
        let manager = DensityModeManager(initialMode: .full, configWriter: writer)

        manager.setMode(.minimal)
        manager.setMode(.off)
        manager.setMode(.full)

        XCTAssertEqual(manager.mode, .full)
        XCTAssertEqual(writer.writes, ["minimal", "off", "full"],
                       "Each transition persists once, in order")
    }

    // MARK: - AnimationEngine interaction

    /// Transition into a non-animating mode must call `suppressAll` on the
    /// wired AnimationEngine. Transitions into `.full` must NOT, since there
    /// may be a legitimate in-flight animation we'd be canceling for no reason.
    func testTransitionIntoMinimalSuppressesAnimations() {
        let writer = StubWriter()
        let engine = AnimationEngine()
        let manager = DensityModeManager(
            initialMode: .full,
            configWriter: writer,
            animationEngine: engine
        )

        let layer = CALayer()
        let curve = SkinContext.ResolvedCurve(duration: 1.0, timingFunction: .linear, isSpring: false)
        let anim = SkinContext.ResolvedAnimation(default: curve, fill: nil, corner: nil)
        let resolved = SkinContext.ResolvedSurface(
            fill: .color(.red),
            border: nil,
            corner: .uniform(4),
            padding: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
            shadow: nil,
            font: nil,
            text: SkinContext.ResolvedText(color: .white, shadow: nil),
            animation: anim,
            states: []
        )
        engine.animateSurface(.tabBarContainer, to: resolved, on: layer, with: anim)
        XCTAssertFalse(engine.activeAnimations.isEmpty, "precondition: animation queued")

        manager.setMode(.minimal)

        XCTAssertTrue(engine.activeAnimations.isEmpty,
                      "Entering minimal must drain active animations via suppressAll")
    }

    func testTransitionIntoOffSuppressesAnimations() {
        let writer = StubWriter()
        let engine = AnimationEngine()
        let manager = DensityModeManager(
            initialMode: .full,
            configWriter: writer,
            animationEngine: engine
        )

        let layer = CALayer()
        let curve = SkinContext.ResolvedCurve(duration: 1.0, timingFunction: .linear, isSpring: false)
        let anim = SkinContext.ResolvedAnimation(default: curve, fill: nil, corner: nil)
        let resolved = SkinContext.ResolvedSurface(
            fill: .color(.red),
            border: nil,
            corner: .uniform(4),
            padding: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
            shadow: nil,
            font: nil,
            text: SkinContext.ResolvedText(color: .white, shadow: nil),
            animation: anim,
            states: []
        )
        engine.animateSurface(.tabBarContainer, to: resolved, on: layer, with: anim)
        XCTAssertFalse(engine.activeAnimations.isEmpty, "precondition: animation queued")

        manager.setMode(.off)

        XCTAssertTrue(engine.activeAnimations.isEmpty)
    }

    func testTransitionIntoFullDoesNotSuppressAnimations() {
        let writer = StubWriter()
        let engine = AnimationEngine()
        let manager = DensityModeManager(
            initialMode: .minimal,
            configWriter: writer,
            animationEngine: engine
        )

        // Mid-flight animation queued directly (bypassing density gate, which
        // would no-op in minimal anyway — we want the engine to have an entry).
        let layer = CALayer()
        let curve = SkinContext.ResolvedCurve(duration: 1.0, timingFunction: .linear, isSpring: false)
        let anim = SkinContext.ResolvedAnimation(default: curve, fill: nil, corner: nil)
        let resolved = SkinContext.ResolvedSurface(
            fill: .color(.red),
            border: nil,
            corner: .uniform(4),
            padding: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
            shadow: nil,
            font: nil,
            text: SkinContext.ResolvedText(color: .white, shadow: nil),
            animation: anim,
            states: []
        )
        engine.animateSurface(.tabBarContainer, to: resolved, on: layer, with: anim)
        let countBefore = engine.activeAnimations.count

        manager.setMode(.full)

        XCTAssertEqual(engine.activeAnimations.count, countBefore,
                       "Entering full must NOT cancel in-flight animations")
    }

    // MARK: - Mode enum round-trip

    func testModeIsCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for mode in DensityModeManager.Mode.allCases {
            let data = try encoder.encode(mode)
            let decoded = try decoder.decode(DensityModeManager.Mode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }

    // MARK: - Convenience init load-from-config

    /// Write a HoloscapeConfig into a unique temp directory and return a
    /// ConfigService pointed at it via the injectable `init(configDir:)`.
    /// Avoids process-global `setenv`, which is unsafe under parallel
    /// XCTest execution. Temp directories are registered for teardown.
    private func makeTempConfigService(
        chromeRegions: ChromeRegionState?
    ) throws -> ConfigService {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holoscape-dmm-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temp)
        }

        var config = HoloscapeConfig.default
        config.chromeRegions = chromeRegions

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)
        try data.write(to: temp.appendingPathComponent("config.json"))

        return ConfigService(configDir: temp)
    }

    func testConvenienceInitLoadsPersistedMinimalMode() throws {
        let state = ChromeRegionState(
            topCollapsed: false, rightCollapsed: false,
            bottomCollapsed: false, leftCollapsed: false,
            densityMode: "minimal"
        )
        let service = try makeTempConfigService(chromeRegions: state)
        let manager = DensityModeManager(configService: service)
        XCTAssertEqual(manager.mode, .minimal)
    }

    func testConvenienceInitLoadsPersistedOffMode() throws {
        let state = ChromeRegionState(
            topCollapsed: false, rightCollapsed: false,
            bottomCollapsed: false, leftCollapsed: false,
            densityMode: "off"
        )
        let service = try makeTempConfigService(chromeRegions: state)
        let manager = DensityModeManager(configService: service)
        XCTAssertEqual(manager.mode, .off)
    }

    func testConvenienceInitFallsBackToFullOnNilChromeRegions() throws {
        let service = try makeTempConfigService(chromeRegions: nil)
        let manager = DensityModeManager(configService: service)
        XCTAssertEqual(manager.mode, .full, "Missing chromeRegions must degrade to .full")
    }

    func testConvenienceInitFallsBackToFullOnUnknownRawValue() throws {
        let state = ChromeRegionState(
            topCollapsed: false, rightCollapsed: false,
            bottomCollapsed: false, leftCollapsed: false,
            densityMode: "legacy-garbage"
        )
        let service = try makeTempConfigService(chromeRegions: state)
        let manager = DensityModeManager(configService: service)
        XCTAssertEqual(manager.mode, .full,
                       "Corrupt densityMode raw value must degrade to .full, not crash")
    }

    // MARK: - Additional transition paths

    /// The second suppressAll on an already-drained engine must still be
    /// a safe no-op; contract is that any transition into a non-animating
    /// mode enforces suppression regardless of prior state.
    func testMinimalToOffTransitionStillCallsSuppressAll() {
        let writer = StubWriter()
        let engine = AnimationEngine()
        let manager = DensityModeManager(
            initialMode: .minimal,
            configWriter: writer,
            animationEngine: engine
        )
        XCTAssertTrue(engine.activeAnimations.isEmpty, "precondition: nothing active")

        manager.setMode(.off)

        XCTAssertEqual(manager.mode, .off)
        XCTAssertTrue(engine.activeAnimations.isEmpty)
    }

    /// A same-mode setMode must not post `.densityModeDidChange`. Observers
    /// acting on the notification would otherwise loop or double-fire.
    func testSetModeToSameValueDoesNotPostNotification() {
        let manager = DensityModeManager(initialMode: .minimal, configWriter: StubWriter())

        let spurious = expectation(forNotification: .densityModeDidChange, object: manager, handler: nil)
        spurious.isInverted = true

        manager.setMode(.minimal)

        wait(for: [spurious], timeout: 0.1)
    }
}
