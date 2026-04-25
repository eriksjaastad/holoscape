import XCTest
import AppKit
@testable import Holoscape

@MainActor
final class MainWindowControllerVesselLayoutTests: XCTestCase {

    func testMercuryDeckWrapsSidebarAndScreenContentInVessels() throws {
        let controller = try makeController(persistedSkin: "MercuryDeck")
        drainMainQueue()
        controller.window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.activeSkinLayoutForTesting?.channelVessel?.size, 248)
        XCTAssertEqual(controller.activeSkinLayoutForTesting?.vesselGap, 20)
        XCTAssertEqual(controller.activeSkinLayoutForTesting?.channelVessel?.height, 618)
        XCTAssertEqual(controller.activeSkinLayoutForTesting?.channelVessel?.verticalAlign, .top)
        XCTAssertEqual(controller.activeSkinLayoutForTesting?.channelVessel?.verticalOffset, 18)
        XCTAssertEqual(controller.activeSkinLayoutForTesting?.channelVessel?.variant, .mercuryControlSpine)
        XCTAssertEqual(controller.activeSkinLayoutForTesting?.screenVessel?.variant, .mercuryScreenBody)
        XCTAssertTrue(controller.channelVesselViewForTesting.superview === controller.sidebarContainerForTesting)
        XCTAssertTrue(controller.sessionLauncherForTesting.superview === controller.channelVesselViewForTesting.topCapView)
        XCTAssertTrue(controller.sidebarViewForTesting.superview === controller.channelVesselViewForTesting.viewportView)
        XCTAssertTrue(controller.rightPaneContentHostForTesting.superview === controller.screenVesselViewForTesting.viewportView)
        XCTAssertTrue(controller.rightPaneForTesting.subviews.contains { $0.subviews.contains(controller.screenVesselViewForTesting) })
        XCTAssertTrue(controller.rightPaneForTesting.subviews.contains { $0.subviews.contains(controller.vesselSeamViewForTesting) })
        XCTAssertEqual(round(controller.vesselSeamViewForTesting.frame.width), 20)
    }

    func testMercuryDeckAppliesChannelHeightAndTopOffset() throws {
        let controller = try makeController(persistedSkin: "MercuryDeck")
        drainMainQueue()
        controller.window.contentView?.layoutSubtreeIfNeeded()

        let root = try XCTUnwrap(controller.window.contentView)
        let sidebarFrame = controller.sidebarContainerForTesting.convert(
            controller.sidebarContainerForTesting.bounds,
            to: root
        )
        let channelFrame = controller.channelVesselViewForTesting.convert(
            controller.channelVesselViewForTesting.bounds,
            to: root
        )

        XCTAssertEqual(channelFrame.height, 618, accuracy: 0.5)
        XCTAssertEqual(sidebarFrame.maxY - channelFrame.maxY, 18, accuracy: 0.5)
    }

    func testTrafficLightsLandInsideMainBodyZone() throws {
        let controller = try makeController(persistedSkin: "MercuryDeck")
        drainMainQueue()
        controller.window.contentView?.layoutSubtreeIfNeeded()

        let root = try XCTUnwrap(controller.window.contentView)
        let close = try XCTUnwrap(controller.chromeWindowControlButton(.closeButton))
        let screenFrame = controller.screenVesselViewForTesting.convert(
            controller.screenVesselViewForTesting.bounds,
            to: root
        )
        let buttonFrame = close.convert(close.bounds, to: root)

        XCTAssertGreaterThanOrEqual(buttonFrame.minX, screenFrame.minX,
                                    "Detached traffic lights should land on the main text body, not the channel spine")
        XCTAssertLessThanOrEqual(buttonFrame.maxX, screenFrame.maxX)
    }

    func testSwitchingBackToDefaultRestoresLegacyInternalStructure() throws {
        let controller = try makeController(persistedSkin: "MercuryDeck")
        drainMainQueue()

        controller.reloadSkin(named: "Default")
        drainMainQueue()
        controller.window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertNil(controller.activeSkinLayoutForTesting)
        XCTAssertTrue(controller.sessionLauncherForTesting.superview === controller.sidebarContainerForTesting)
        XCTAssertTrue(controller.sidebarViewForTesting.superview === controller.sidebarContainerForTesting)
        XCTAssertTrue(controller.rightPaneContentHostForTesting.superview === controller.rightPaneForTesting)
        XCTAssertNil(controller.channelVesselViewForTesting.superview)
        XCTAssertFalse(controller.rightPaneForTesting.subviews.contains { $0.subviews.contains(controller.screenVesselViewForTesting) })
    }

    func testSidebarCollapseStillControlsTopTabBarWithVessels() throws {
        let controller = try makeController(persistedSkin: "MercuryDeck")
        drainMainQueue()

        XCTAssertTrue(controller.tabBarForTesting.isHidden)
        controller.toggleSidebar()
        drainMainQueue()

        XCTAssertTrue(controller.sidebarContainerForTesting.isHidden)
        XCTAssertFalse(controller.tabBarForTesting.isHidden)
    }

    private func makeController(persistedSkin: String) throws -> MainWindowController {
        _ = NSApplication.shared

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainWindowControllerVesselLayoutTests-\(UUID().uuidString)")
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
