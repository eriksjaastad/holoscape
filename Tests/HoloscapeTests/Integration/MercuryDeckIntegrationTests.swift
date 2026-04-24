import XCTest
@testable import Holoscape

/// Mercury Deck scaffold verification.
///
/// Pins the new hero-skin scaffold as a real bundled v4 baked skin
/// rather than a docs-only concept. Coverage mirrors the minimum
/// bundle/load/controller lifecycle expectations used for the current
/// shipped chrome references.
@MainActor
final class MercuryDeckIntegrationTests: XCTestCase {

    func testMercuryDeckIsBundledAndDiscoverable() throws {
        let engine = SkinEngine()
        XCTAssertTrue(engine.availableSkins().contains("MercuryDeck"))
    }

    func testManifestLoadsWithBakedChromeField() throws {
        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "MercuryDeck")

        XCTAssertNotNil(loaded.chrome)
        XCTAssertEqual(loaded.chrome?.mode, .baked)
        XCTAssertEqual(loaded.chrome?.width, 1000)
        XCTAssertEqual(loaded.chrome?.height, 700)
        XCTAssertEqual(loaded.chrome?.interiorRect, SkinRect(x: 16, y: 40, width: 968, height: 644))
        XCTAssertEqual(loaded.layout?.vesselGap, 20)
        XCTAssertEqual(loaded.layout?.channelVessel?.dock, .left)
        XCTAssertEqual(loaded.layout?.channelVessel?.size, 248)
        XCTAssertEqual(loaded.layout?.channelVessel?.height, 618)
        XCTAssertEqual(loaded.layout?.channelVessel?.verticalAlign, .top)
        XCTAssertEqual(loaded.layout?.channelVessel?.verticalOffset, 18)
        XCTAssertEqual(loaded.layout?.channelVessel?.variant, .mercuryControlSpine)
        XCTAssertEqual(loaded.layout?.screenVessel?.variant, .mercuryScreenBody)
        XCTAssertEqual(loaded.layout?.seam?.thickness, 20)
        XCTAssertEqual(loaded.layout?.seam?.style, .mechanical)
    }

    func testAmbientAnimationsDeclared() throws {
        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "MercuryDeck")
        let animations = loaded.chrome?.animations ?? []

        XCTAssertEqual(animations.count, 3)
        XCTAssertEqual(animations.first?.kind, .ledArray)
        XCTAssertEqual(animations.filter { $0.kind == .shader }.count, 2,
                       "Mercury Deck scaffold keeps motion ambient: one LED array and two subtle shaders")
    }

    func testBakePipelineProducesBaseImage() throws {
        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "MercuryDeck")

        XCTAssertNotNil(loaded.baseImage)
        XCTAssertNotNil(loaded.chromeSHA)
        XCTAssertEqual(loaded.baseImage?.width, 2000)
        XCTAssertEqual(loaded.baseImage?.height, 1400)
    }

    func testValidatorAcceptsSkin() throws {
        let engine = SkinEngine()
        let loaded = try engine.loadComposite(named: "MercuryDeck")

        guard let validation = loaded.chromeValidation else {
            return XCTFail("Validator must run on every v4 skin load")
        }
        XCTAssertTrue(validation.valid)
        XCTAssertTrue(validation.disabledAnimationIDs.isEmpty)
    }

    func testPersistedMercuryDeckLaunchBuildsFullControllerHierarchy() throws {
        let controller = try makeController(persistedSkin: "MercuryDeck")
        drainMainQueue()

        XCTAssertTrue(controller.window is ShapedBorderlessWindow)
        let root = try XCTUnwrap(controller.window.contentView)
        let interior = try XCTUnwrap(controller.currentChromeInteriorView)
        XCTAssertTrue(root.subviews.contains { $0 === interior })
        XCTAssertTrue(controller.appContentHost.superview === interior)
        XCTAssertNotNil(controller.chromeWindowControlButton(.closeButton))
        XCTAssertNotNil(controller.chromeWindowControlButton(.miniaturizeButton))
        XCTAssertNotNil(controller.chromeWindowControlButton(.zoomButton))
    }

    func testPersistedMercuryDeckPlacesTrafficLightsOnMainTextBody() throws {
        let controller = try makeController(persistedSkin: "MercuryDeck")
        drainMainQueue()

        let close = try XCTUnwrap(controller.chromeWindowControlButton(.closeButton))
        let expectedX: CGFloat = 319
        let expectedY: CGFloat = 663

        XCTAssertEqual(close.frame.minX, expectedX, accuracy: 0.5,
                       "Mercury Deck traffic lights should be centered in the generated main-body landing dock")
        XCTAssertEqual(close.frame.minY, expectedY, accuracy: 0.5,
                       "Mercury Deck traffic lights should align vertically inside the generated landing dock")
    }

    func testPersistedMercuryDeckInstallsMainBodyDragShelf() throws {
        let controller = try makeController(persistedSkin: "MercuryDeck")
        drainMainQueue()

        XCTAssertEqual(controller.chromeDragOverlaysForTesting.count, 5)

        let mainOverlay = try XCTUnwrap(controller.chromeDragOverlaysForTesting.first {
            abs($0.frame.minX - 284) < 0.5
                && abs($0.frame.minY - 622) < 0.5
        })
        XCTAssertEqual(mainOverlay.frame.width, 710, accuracy: 0.5)
        XCTAssertEqual(mainOverlay.frame.height, 70, accuracy: 0.5)

        let leftRailOverlay = try XCTUnwrap(controller.chromeDragOverlaysForTesting.first {
            abs($0.frame.minX - 284) < 0.5
                && abs($0.frame.minY - 28) < 0.5
        })
        XCTAssertEqual(leftRailOverlay.frame.width, 18, accuracy: 0.5)
        XCTAssertEqual(leftRailOverlay.frame.height, 594, accuracy: 0.5)

        let spineOverlay = try XCTUnwrap(controller.chromeDragOverlaysForTesting.first {
            abs($0.frame.minX - 4) < 0.5
        })
        XCTAssertEqual(spineOverlay.frame.minY, 603, accuracy: 0.5)
        XCTAssertEqual(spineOverlay.frame.width, 242, accuracy: 0.5)
        XCTAssertEqual(spineOverlay.frame.height, 39, accuracy: 0.5)
    }

    func testSwitchingFromMercuryDeckToDefaultLeavesWindowHierarchySane() throws {
        let controller = try makeController(persistedSkin: "MercuryDeck")
        drainMainQueue()

        controller.reloadSkin(named: "Default")
        drainMainQueue()

        XCTAssertFalse(controller.window is ShapedBorderlessWindow)
        XCTAssertTrue(controller.window.styleMask.contains(.titled))
        XCTAssertTrue(controller.window.styleMask.contains(.resizable))
        let root = try XCTUnwrap(controller.window.contentView)
        XCTAssertTrue(controller.appContentHost.superview === root)
        XCTAssertEqual(root.subviews.filter { $0 === controller.appContentHost }.count, 1)
        XCTAssertNotNil(controller.window.standardWindowButton(.zoomButton))
    }

    private func makeController(persistedSkin: String) throws -> MainWindowController {
        _ = NSApplication.shared

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MercuryDeckIntegrationTests-\(UUID().uuidString)")
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
