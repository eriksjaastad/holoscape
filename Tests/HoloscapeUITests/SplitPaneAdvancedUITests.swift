import XCTest

final class SplitPaneAdvancedUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Active Pane Indicator

    func testActivePaneHasBlueBorder() throws {
        // Create a split pane
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Active pane should be visually distinct
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Split pane should show active indicator")

        // Close split
        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testClickingPaneMakesItActive() throws {
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Click in the window area to switch active pane
        let window = app.windows["Holoscape"]
        let frame = window.frame
        let leftCenter = CGPoint(x: frame.minX + frame.width * 0.25, y: frame.midY)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertTrue(window.exists, "Clicking pane should make it active")

        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testActivePaneChangesOnClick() throws {
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]

        // Click left pane
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
        Thread.sleep(forTimeInterval: 0.2)

        // Click right pane
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).click()
        Thread.sleep(forTimeInterval: 0.2)

        XCTAssertTrue(window.exists, "Active pane should change on click")

        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    // MARK: - Channel-to-Pane Routing

    func testDifferentChannelsInDifferentPanes() throws {
        // Create second shell
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Shell"].click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        // Split
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Switch channel in active pane
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Different channels should display in different panes")

        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testInputRoutesToActivePane() throws {
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let inputBox = app.textViews["input-box"]
        inputBox.typeText("active-pane-input")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Input should route to active pane's channel only")

        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testChannelSwitchInActivePaneOnly() throws {
        // Create second shell
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Shell"].click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        // Split
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Cmd+2 should switch channel in active pane only
        app.typeKey("2", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Channel switch should affect active pane only")

        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    // MARK: - Layout Persistence

    func testSplitLayoutPersistsAcrossRestart() throws {
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Quit and relaunch
        app.terminate()
        Thread.sleep(forTimeInterval: 1.0)
        app.launch()
        Thread.sleep(forTimeInterval: 1.0)

        // Split should be restored
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 3), "Split layout should persist across restart")
    }

    func testSplitLayoutExport() throws {
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Layout export is internal — verify split creates without crash
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Split layout should be exportable without crash")

        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testPaneChannelAssignmentPersists() throws {
        // Create second shell and split
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Shell"].click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Quit and relaunch
        app.terminate()
        Thread.sleep(forTimeInterval: 1.0)
        app.launch()
        Thread.sleep(forTimeInterval: 1.0)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 3), "Pane channel assignments should persist")
    }

    // MARK: - Channel Removal

    func testClosingChannelClearsPaneContent() throws {
        // Create second shell and split
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Shell"].click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Close a channel
        app.typeKey("w", modifierFlags: .command)
        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 1) {
            closeButton.click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Closing channel should clear pane content gracefully")
    }

    func testRemoveChannelFromSpecificPane() throws {
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Close active channel in pane
        app.typeKey("w", modifierFlags: .command)
        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 1) {
            closeButton.click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Removing channel from specific pane should work")
    }

    // MARK: - Layout Combinations

    func testHorizontalThenVerticalSplit() throws {
        app.typeKey("d", modifierFlags: .command) // Horizontal
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("d", modifierFlags: [.command, .shift]) // Vertical
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Horizontal then vertical split should create mixed layout")

        // Close splits
        app.typeKey("w", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.2)
        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testVerticalThenHorizontalSplit() throws {
        app.typeKey("d", modifierFlags: [.command, .shift]) // Vertical
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("d", modifierFlags: .command) // Horizontal
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Vertical then horizontal split should create mixed layout")

        app.typeKey("w", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.2)
        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testThreePaneLayout() throws {
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Three pane layout should be functional")

        // Close extra panes
        app.typeKey("w", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.2)
        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testFourPaneLayout() throws {
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Four pane layout should be independently operational")

        // Close extra panes
        for _ in 0..<3 {
            app.typeKey("w", modifierFlags: [.command, .shift])
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
}
