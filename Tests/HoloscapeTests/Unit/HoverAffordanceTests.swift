import AppKit
import XCTest
@testable import Holoscape

@MainActor
final class HoverAffordanceTests: XCTestCase {
    func testReliableHoverButtonKeepsOneAlwaysActiveTrackingAreaAcrossLayoutRefreshes() {
        let button = HoverTrackingButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))

        button.updateTrackingAreas()
        button.updateTrackingAreas()

        let areas = button.hoverTrackingAreasForTesting
        XCTAssertEqual(areas.count, 1)
        XCTAssertTrue(areas[0].options.contains(.mouseEnteredAndExited))
        XCTAssertTrue(areas[0].options.contains(.activeAlways))
        XCTAssertTrue(areas[0].options.contains(.inVisibleRect))
    }

    func testReliableHoverButtonReconcilesStationaryPointerStateIdempotently() {
        let button = RecordingHoverButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))

        button.reconcileHoverState(pointerInside: true, applicationIsActive: true)
        button.reconcileHoverState(pointerInside: true, applicationIsActive: true)
        button.reconcileHoverState(pointerInside: false, applicationIsActive: true)

        XCTAssertEqual(button.hoverChanges, [true, false])
        XCTAssertFalse(button.isPointerInside)
    }

    func testReliableHoverButtonSuppressesPointerInsideStateWhileApplicationIsInactive() {
        let button = RecordingHoverButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))

        button.reconcileHoverState(pointerInside: true, applicationIsActive: false)
        XCTAssertFalse(button.isPointerInside)
        XCTAssertTrue(button.hoverChanges.isEmpty)

        button.reconcileHoverState(pointerInside: true, applicationIsActive: true)
        XCTAssertTrue(button.isPointerInside)
        XCTAssertEqual(button.hoverChanges, [true])
    }

    func testLauncherControlsExposeStableLabelsWithoutHover() {
        let launcher = SessionLauncherView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))

        XCTAssertEqual(launcher.comboBoxForTesting.accessibilityLabel(), "New channel launcher")
        XCTAssertEqual(launcher.refreshButtonForTesting.accessibilityLabel(), "Refresh projects")
        XCTAssertEqual(launcher.refreshButtonForTesting.toolTip, "Refresh project list")
    }

    func testSidebarHoverDoesNotHideAttentionOrActiveState() {
        let entry = SidebarTabEntry(frame: NSRect(x: 0, y: 0, width: 220, height: 36))

        entry.reconcileHoverState(pointerInside: true, applicationIsActive: true)

        XCTAssertEqual(entry.rowSurfaceKey(isActive: false, preservesSemanticState: false), .sidebarRowHover)
        XCTAssertEqual(entry.rowSurfaceKey(isActive: false, preservesSemanticState: true), .sidebarRowNormal)
        XCTAssertEqual(entry.rowSurfaceKey(isActive: true, preservesSemanticState: true), .sidebarRowSelected)
    }

    private final class RecordingHoverButton: HoverTrackingButton {
        var hoverChanges: [Bool] = []

        override func hoverStateDidChange(isInside: Bool) {
            hoverChanges.append(isInside)
        }
    }
}
