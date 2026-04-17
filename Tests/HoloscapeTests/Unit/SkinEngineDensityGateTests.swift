import XCTest
@testable import Holoscape

/// Task 7.2 — SkinEngine density gate: `apply()` must return its input
/// unchanged when the DensityModeManager says skin is not active (Off mode).
/// When no manager is wired, behavior matches the pre-gate default
/// (application proceeds normally).
@MainActor
final class SkinEngineDensityGateTests: XCTestCase {

    private final class StubWriter: DensityModeConfigWriter {
        func writeDensityMode(_ modeRawValue: String) {}
    }

    private func makeSkin() -> SkinDefinition {
        var skin = SkinDefinition()
        skin.windowBackground = "#123456"
        skin.textForeground = "#fedcba"
        skin.ansiColors = [
            "#000000", "#aa0000", "#00aa00", "#aaaa00",
            "#0000aa", "#aa00aa", "#00aaaa", "#aaaaaa",
            "#555555", "#ff5555", "#55ff55", "#ffff55",
            "#5555ff", "#ff55ff", "#55ffff", "#ffffff",
        ]
        return skin
    }

    private func defaultConfig() -> AppearanceConfig {
        AppearanceConfig.default
    }

    // MARK: - Off mode bypass

    func testApplyWithOffModeReturnsConfigUnchanged() {
        let density = DensityModeManager(initialMode: .off, configWriter: StubWriter())
        let engine = SkinEngine()
        engine.densityModeManager = density

        let input = defaultConfig()
        let output = engine.apply(skin: makeSkin(), to: input)

        XCTAssertEqual(output, input,
                       "Off mode must bypass the skin engine entirely — config returns unchanged")
    }

    // MARK: - Full mode passes through

    func testApplyWithFullModeAppliesSkinNormally() {
        let density = DensityModeManager(initialMode: .full, configWriter: StubWriter())
        let engine = SkinEngine()
        engine.densityModeManager = density

        let input = defaultConfig()
        let output = engine.apply(skin: makeSkin(), to: input)

        XCTAssertEqual(output.backgroundColor, "#123456",
                       "Full mode must apply windowBackground override")
        XCTAssertEqual(output.ansiColors?["foreground"], "#fedcba",
                       "Full mode must fold textForeground into ansiColors[foreground]")
        XCTAssertEqual(output.ansiColors?["red"], "#aa0000")
    }

    // MARK: - Minimal mode still applies colors

    /// Minimal mode suppresses images and animations but NOT color fills;
    /// skin-engine.apply() operates on color-only AppearanceConfig, so
    /// Minimal behaves like Full for this code path. (Image handling
    /// lands in Task 8.1.)
    func testApplyWithMinimalModeStillAppliesColors() {
        let density = DensityModeManager(initialMode: .minimal, configWriter: StubWriter())
        let engine = SkinEngine()
        engine.densityModeManager = density

        let output = engine.apply(skin: makeSkin(), to: defaultConfig())

        XCTAssertEqual(output.backgroundColor, "#123456",
                       "Minimal mode still applies color overrides — only images are gated")
    }

    // MARK: - Nil manager default-open

    func testApplyWithoutManagerAppliesSkinNormally() {
        let engine = SkinEngine()
        // No densityModeManager wired — behavior should match pre-gate era.

        let output = engine.apply(skin: makeSkin(), to: defaultConfig())

        XCTAssertEqual(output.backgroundColor, "#123456",
                       "Nil density manager must not suppress skin application")
    }

    // MARK: - AppearanceSettingsWindowController wiring

    /// The settings window's internal `SkinEngine` must pick up the density
    /// manager passed at init — otherwise the gate is default-open in the
    /// one place in production that actually calls `skinEngine.apply()`.
    func testAppearanceSettingsWiresDensityManagerIntoSkinEngine() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("holoscape-sews-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temp) }

        let service = ConfigService(configDir: temp)
        let manager = DensityModeManager(configService: service)

        let wc = AppearanceSettingsWindowController(
            config: service.load().appearance,
            configService: service,
            densityModeManager: manager
        )

        // Behavioral verification: the settings window's internal SkinEngine
        // must hold the exact same manager instance we passed in. A broken
        // wiring (e.g., nil assignment) or an accidental re-init would fail
        // this identity check.
        XCTAssertTrue(wc._densityManagerOnSkinEngine === manager,
                      "Settings SkinEngine must be wired to the passed-in DensityModeManager")
    }

    func testAppearanceSettingsDefaultsGateOpenWhenNoManagerPassed() {
        let service = ConfigService()  // production config dir; read-only for this test
        let wc = AppearanceSettingsWindowController(
            config: service.load().appearance,
            configService: service,
            densityModeManager: nil
        )
        XCTAssertNil(wc._densityManagerOnSkinEngine,
                     "Nil densityModeManager leaves the SkinEngine gate default-open")
    }
}
