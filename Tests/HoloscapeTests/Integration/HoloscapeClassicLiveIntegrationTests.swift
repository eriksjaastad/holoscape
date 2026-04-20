import XCTest
@testable import Holoscape

/// Chrome v4 Task 27.3 — HoloscapeClassic-live skin end-to-end load.
///
/// First integration test for a v4 chrome skin. Asserts the complete
/// pipeline — manifest decode, bake (baked mode so image decodes from
/// disk), validator accept, all four animation-kind renderers install
/// — works against a real bundled skin on disk.
///
/// This is the dogfood for Phase 2's animated-layer system.
@MainActor
final class HoloscapeClassicLiveIntegrationTests: XCTestCase {

    func testManifestLoadsWithChromeField() throws {
        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "HoloscapeClassic-live")

        XCTAssertNotNil(loaded.chrome,
            "HoloscapeClassic-live manifest must decode with a chrome field (v4)")
        XCTAssertEqual(loaded.chrome?.mode, .baked)
        XCTAssertEqual(loaded.chrome?.width, 1000)
        XCTAssertEqual(loaded.chrome?.height, 700)
    }

    func testFourAnimationsDeclared() throws {
        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "HoloscapeClassic-live")
        let animations = loaded.chrome?.animations ?? []

        XCTAssertEqual(animations.count, 4,
            "HoloscapeClassic-live ships all four animation kinds")

        let kinds = Set(animations.map { $0.kind })
        XCTAssertEqual(kinds, Set([.particle, .ledArray, .spriteAnim, .shader]),
            "Every ChromeAnimationLayer.Kind must appear exactly once")
    }

    func testBakePipelineProducesBaseImage() throws {
        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "HoloscapeClassic-live")

        XCTAssertNotNil(loaded.baseImage,
            "Bake pipeline must produce a Base_Layer image for a v4 skin")
        XCTAssertNotNil(loaded.chromeSHA)
        // 2x pixels for 1000×700 logical.
        XCTAssertEqual(loaded.baseImage?.width, 2000)
        XCTAssertEqual(loaded.baseImage?.height, 1400)
    }

    func testValidatorAcceptsSkin() throws {
        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "HoloscapeClassic-live")

        guard let validation = loaded.chromeValidation else {
            return XCTFail("Validator must run on every v4 skin load")
        }
        XCTAssertTrue(validation.valid,
            "HoloscapeClassic-live must pass the validator — shipping a broken reference skin would block every downstream PR")
        XCTAssertTrue(validation.disabledAnimationIDs.isEmpty,
            "No animation must be disabled in the reference skin")
    }

    func testChromeHostInstallsAllRenderers() throws {
        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "HoloscapeClassic-live")
        guard let chrome = loaded.chrome, let baseImage = loaded.baseImage else {
            return XCTFail("prerequisite — skin must load")
        }

        let host = ChromeHostView(chrome: chrome, baseImage: baseImage, clock: SharedAnimationClock())
        host.installAnimatedLayers(chrome.animations ?? [])

        XCTAssertEqual(host.renderers.count, 4,
            "Every ChromeAnimationLayer must instantiate a renderer")

        // Verify one instance of each concrete renderer class.
        let types = host.renderers.map { ObjectIdentifier(type(of: $0)) }
        XCTAssertEqual(Set(types).count, 4,
            "One renderer class per kind — no duplicates")
    }
}
