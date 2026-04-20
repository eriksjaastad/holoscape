import XCTest
@testable import Holoscape

/// Chrome v4 Task 29.2 + 31.2 — migration verification.
///
/// Asserts HoloscapeSynthwave + AmplifyDemo now declare v4 chrome
/// AND continue to load successfully through the full pipeline.
/// Both skins were v3 on main; this PR migrated them to v4 composed
/// mode. The existing `BackwardCompatIntegrationTests` already pins
/// that these skins load through SkinEngine — these tests pin the
/// v4-specific fields.
@MainActor
final class V4MigrationIntegrationTests: XCTestCase {

    func testSynthwaveDeclaresV4Chrome() throws {
        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "HoloscapeSynthwave")

        XCTAssertNotNil(loaded.chrome, "Synthwave migrated to v4 composed")
        XCTAssertEqual(loaded.chrome?.mode, .composed)
        XCTAssertEqual(loaded.chrome?.width, 1000)
        XCTAssertEqual(loaded.chrome?.height, 700)

        let animations = loaded.chrome?.animations ?? []
        XCTAssertEqual(animations.count, 2,
            "Synthwave ships two ambient animations: particle + scanlines")
        let kinds = Set(animations.map { $0.kind })
        XCTAssertEqual(kinds, Set([.particle, .shader]))
    }

    func testAmplifyDemoDeclaresV4Chrome() throws {
        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "AmplifyDemo")

        XCTAssertNotNil(loaded.chrome, "AmplifyDemo migrated to v4 composed")
        XCTAssertEqual(loaded.chrome?.mode, .composed)

        let animations = loaded.chrome?.animations ?? []
        XCTAssertEqual(animations.count, 1,
            "AmplifyDemo is the minimal-animations reference — single glow")
        XCTAssertEqual(animations.first?.kind, .shader)
    }

    func testSynthwaveBakePipelineProducesImage() throws {
        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "HoloscapeSynthwave")
        XCTAssertNotNil(loaded.baseImage,
            "Composed-mode bake must produce a CGImage for Synthwave")
        XCTAssertEqual(loaded.baseImage?.width, 2000)
        XCTAssertEqual(loaded.baseImage?.height, 1400)
    }

    func testAmplifyDemoBakePipelineProducesImage() throws {
        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "AmplifyDemo")
        XCTAssertNotNil(loaded.baseImage)
    }

    func testSynthwaveValidatorAcceptsSkin() throws {
        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "HoloscapeSynthwave")
        XCTAssertTrue(loaded.chromeValidation?.valid ?? false,
            "Synthwave must pass the validator after v4 migration")
    }

    func testAmplifyDemoValidatorAcceptsSkin() throws {
        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "AmplifyDemo")
        XCTAssertTrue(loaded.chromeValidation?.valid ?? false,
            "AmplifyDemo must pass the validator after v4 migration")
    }
}
