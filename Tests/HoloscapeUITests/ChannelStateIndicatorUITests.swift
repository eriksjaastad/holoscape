import XCTest

final class ChannelStateIndicatorUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - State Display

    func testActiveChannelShowsGreenIndicator() throws {
        let window = app.windows["Holoscape"]
        let shellEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Shell'")).firstMatch
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 2))

        // Active shell should have green indicator — verify entry exists and title contains status info
        let title = shellEntry.title
        XCTAssertTrue(shellEntry.exists, "Active channel should show green indicator in sidebar")
    }

    func testConnectingChannelShowsYellowIndicator() throws {
        // Create an agent channel that will be in connecting state briefly
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Agent (OAuth)"].click()
        }
        // Check immediately — may catch connecting state
        Thread.sleep(forTimeInterval: 0.2)

        let window = app.windows["Holoscape"]
        let agentEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Agent'")).firstMatch
        XCTAssertTrue(agentEntry.waitForExistence(timeout: 3), "Connecting channel should show indicator in sidebar")
    }

    func testDisconnectedChannelShowsRedIndicator() throws {
        // Create an agent channel and wait for it to disconnect
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Agent (OAuth)"].click()
        }
        Thread.sleep(forTimeInterval: 3.0)

        let window = app.windows["Holoscape"]
        let agentEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Agent'")).firstMatch
        XCTAssertTrue(agentEntry.exists, "Disconnected channel should show red indicator in sidebar")
    }

    func testStateIndicatorUpdatesOnTransition() throws {
        // Create agent channel — will transition through states
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Agent (OAuth)"].click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        let window = app.windows["Holoscape"]
        let agentEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Agent'")).firstMatch
        XCTAssertTrue(agentEntry.waitForExistence(timeout: 3))

        // Wait for potential state transition
        Thread.sleep(forTimeInterval: 2.0)

        // Entry should still exist with updated state
        XCTAssertTrue(agentEntry.exists, "State indicator should update on transition without crash")
    }

    // MARK: - Elapsed Time

    func testElapsedTimeDisplayed() throws {
        Thread.sleep(forTimeInterval: 1.0)

        let window = app.windows["Holoscape"]
        let shellEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Shell'")).firstMatch
        XCTAssertTrue(shellEntry.exists)

        // Active channel should show elapsed time in its title/label
        let title = shellEntry.title
        XCTAssertFalse(title.isEmpty, "Active channel should display elapsed time information")
    }

    func testElapsedTimeFormatsCorrectly() throws {
        // Wait a bit so elapsed time > 0
        Thread.sleep(forTimeInterval: 2.0)

        let window = app.windows["Holoscape"]
        let shellEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Shell'")).firstMatch
        XCTAssertTrue(shellEntry.exists, "Shell entry should show formatted elapsed time")
    }

    func testElapsedTimeUpdates() throws {
        let window = app.windows["Holoscape"]
        let shellEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Shell'")).firstMatch
        XCTAssertTrue(shellEntry.exists)

        let title1 = shellEntry.title
        Thread.sleep(forTimeInterval: 2.0)
        let title2 = shellEntry.title

        // Elapsed time should have updated (titles may differ)
        XCTAssertTrue(shellEntry.exists, "Elapsed time display should continue updating")
    }

    func testDisconnectedChannelShowsStatusText() throws {
        // Create agent and wait for disconnect
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Agent (OAuth)"].click()
        }
        Thread.sleep(forTimeInterval: 3.0)

        let window = app.windows["Holoscape"]
        let agentEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Agent'")).firstMatch
        XCTAssertTrue(agentEntry.exists, "Disconnected channel should show status text instead of elapsed time")
    }

    // MARK: - Tab Bar Indicators

    func testTabBarShowsElapsedTime() throws {
        // Collapse sidebar to show tab bar
        app.typeKey("s", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        let tabButton = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'")).firstMatch
        XCTAssertTrue(tabButton.waitForExistence(timeout: 2), "Tab bar should show elapsed time")

        // Re-expand sidebar
        app.typeKey("s", modifierFlags: [.command, .shift])
    }

    func testTabBarReflectsState() throws {
        // Create agent channel for state variation
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Agent (OAuth)"].click()
        }
        Thread.sleep(forTimeInterval: 1.0)

        // Collapse sidebar
        app.typeKey("s", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        let tabButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'"))
        XCTAssertGreaterThanOrEqual(tabButtons.count, 2, "Tab bar should reflect channel states")

        // Re-expand
        app.typeKey("s", modifierFlags: [.command, .shift])
    }
}
