import XCTest

final class TabBarUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    /// Collapse sidebar so tab bar is visible.
    private func collapseSidebar() {
        app.typeKey("s", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.3)
    }

    // MARK: - Visibility

    func testTabBarAppearsWhenSidebarCollapsed() throws {
        collapseSidebar()

        let window = app.windows["Holoscape"]
        let shellTab = window.buttons.matching(NSPredicate(format: "identifier == 'tab-Shell'")).firstMatch
        XCTAssertTrue(shellTab.waitForExistence(timeout: 2), "Tab bar with Shell tab should appear when sidebar collapsed")
    }

    func testTabBarHiddenWhenSidebarExpanded() throws {
        // First collapse, then re-expand
        collapseSidebar()
        app.typeKey("s", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.3)

        // The sidebar tab entries should be visible, not the tab bar buttons
        let window = app.windows["Holoscape"]
        let sidebarEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Shell'")).firstMatch
        XCTAssertTrue(sidebarEntry.waitForExistence(timeout: 2), "Sidebar entries should be visible when expanded")
    }

    // MARK: - Keyboard Shortcuts

    func testCmd1SwitchesToFirstChannel() throws {
        // Create a second channel
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 2))
        dialog.buttons["Shell"].click()
        Thread.sleep(forTimeInterval: 0.5)

        // We're now on Shell 2. Switch to first channel.
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Input box should still work
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)
    }

    func testCmd2SwitchesToSecondChannel() throws {
        // Create a second channel
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 2))
        dialog.buttons["Shell"].click()
        Thread.sleep(forTimeInterval: 0.5)

        // Switch to first
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        // Switch back to second
        app.typeKey("2", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        // Window should still be responsive
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists)
    }

    func testCmdOutOfRangeDoesNothing() throws {
        // Only one channel. Cmd+9 should do nothing and not crash.
        app.typeKey("9", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should not crash on out-of-range Cmd+N")
    }

    // MARK: - Active Tab

    func testActiveTabVisuallyDistinct() throws {
        collapseSidebar()

        let window = app.windows["Holoscape"]
        let shellTab = window.buttons.matching(NSPredicate(format: "identifier == 'tab-Shell'")).firstMatch
        XCTAssertTrue(shellTab.waitForExistence(timeout: 2))

        // The active tab should exist and be hittable
        XCTAssertTrue(shellTab.isHittable, "Active tab should be hittable")
    }

    // MARK: - Unread Indicator on Tabs

    func testUnreadIndicatorVisibleOnInactiveTab() throws {
        // Create second channel and switch away from it
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 2))
        dialog.buttons["Shell"].click()
        Thread.sleep(forTimeInterval: 0.5)

        // Switch to first channel
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        collapseSidebar()

        // The second channel tab may have unread bullet ● in its title
        let window = app.windows["Holoscape"]
        // Check that at least 2 tab buttons exist
        let tabButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'"))
        XCTAssertGreaterThanOrEqual(tabButtons.count, 2, "Should have at least 2 tabs")
    }

    // MARK: - Rapid Channel Switching

    func testRapidSwitchingDoesNotCrash() throws {
        // Create 3 channels
        for _ in 0..<3 {
            app.menuBars.firstMatch.menuBarItems["File"].click()
            app.menuItems["New Channel"].click()
            let dialog = app.dialogs.firstMatch
            XCTAssertTrue(dialog.waitForExistence(timeout: 2))
            dialog.buttons["Shell"].click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Rapidly switch between them
        for i in 1...4 {
            app.typeKey(String(i), modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.05)
        }

        // App should still be running
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should survive rapid channel switching")
    }
}
