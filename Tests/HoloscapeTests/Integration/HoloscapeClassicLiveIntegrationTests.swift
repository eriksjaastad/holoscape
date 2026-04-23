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

    func testPersistedClassicLiveLaunchBuildsFullControllerHierarchy() throws {
        let controller = try makeController(persistedSkin: "HoloscapeClassic-live")
        drainMainQueue()

        XCTAssertTrue(controller.window is ShapedBorderlessWindow)
        let root = try XCTUnwrap(controller.window.contentView)
        let interior = try XCTUnwrap(controller.currentChromeInteriorView)
        XCTAssertTrue(root.subviews.contains { $0 === interior })
        XCTAssertTrue(controller.appContentHost.superview === interior,
                      "Bundled v4 launch must wire the controller-owned app host into InteriorView")
        XCTAssertNotNil(controller.chromeWindowControlButton(.closeButton))
        XCTAssertNotNil(controller.chromeWindowControlButton(.miniaturizeButton))
        XCTAssertNotNil(controller.chromeWindowControlButton(.zoomButton))
    }

    func testSwitchingFromClassicLiveToDefaultLeavesWindowHierarchySane() throws {
        let controller = try makeController(persistedSkin: "HoloscapeClassic-live")
        drainMainQueue()

        controller.reloadSkin(named: "Default")
        drainMainQueue()

        XCTAssertFalse(controller.window is ShapedBorderlessWindow)
        XCTAssertTrue(controller.window.styleMask.contains(.titled))
        XCTAssertTrue(controller.window.styleMask.contains(.resizable))
        let root = try XCTUnwrap(controller.window.contentView)
        XCTAssertTrue(controller.appContentHost.superview === root)
        XCTAssertEqual(root.subviews.filter { $0 === controller.appContentHost }.count, 1,
                       "App host should be attached exactly once after leaving chrome mode")
        XCTAssertNotNil(controller.window.standardWindowButton(.zoomButton))
    }

    private func makeController(persistedSkin: String) throws -> MainWindowController {
        _ = NSApplication.shared

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoloscapeClassicLiveIntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let configService = ConfigService(configDir: tempRoot)
        var config = HoloscapeConfig.default
        config.appearance.skinName = persistedSkin
        configService.save(config)

        let channelManager = ChannelManager(configService: configService)
        return MainWindowController(channelManager: channelManager, configService: configService)
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}
