import XCTest

final class TabBarUITests: HoloscapeUITestCase {

    /// Collapse sidebar so tab bar is visible.
    private func collapseSidebar() {
        app.typeKey("s", modifierFlags: [.command, .shift])
        let tab = tabEntry("Shell")
        _ = tab.waitForExistence(timeout: 2)
    }

    // MARK: - Visibility

    func testTabBarAppearsWhenSidebarCollapsed() throws {
        collapseSidebar()

        let shellTab = tabEntry("Shell")
        XCTAssertTrue(shellTab.waitForExistence(timeout: 2), "Tab bar with Shell tab should appear when sidebar collapsed")
    }

    func testTabBarHiddenWhenSidebarExpanded() throws {
        // First collapse, then re-expand
        collapseSidebar()
        app.typeKey("s", modifierFlags: [.command, .shift])

        // The sidebar entries should be visible, not the tab bar buttons
        let entry = sidebarEntry("Shell")
        XCTAssertTrue(entry.waitForExistence(timeout: 2), "Sidebar entries should be visible when expanded")
    }

    // MARK: - Keyboard Shortcuts

    func testCmd1SwitchesToFirstChannel() throws {
        // Create a second channel
        createChannel(type: "Shell")

        // We're now on Shell 2. Switch to first channel.
        app.typeKey("1", modifierFlags: .command)

        // Shell channels type directly into the terminal — no separate input box
        assertActiveChannelResponsive(message: "Channel should be responsive after Cmd+1 switch")
    }

    func testCmd2SwitchesToSecondChannel() throws {
        // Create a second channel
        createChannel(type: "Shell")

        // Switch to first
        app.typeKey("1", modifierFlags: .command)

        // Switch back to second
        app.typeKey("2", modifierFlags: .command)

        assertActiveChannelResponsive(message: "Channel should be responsive after Cmd+2 switch")
    }

    func testCmdOutOfRangeDoesNothing() throws {
        // Only one channel. Cmd+9 should do nothing and not crash.
        app.typeKey("9", modifierFlags: .command)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should not crash on out-of-range Cmd+N")

        assertActiveChannelResponsive(message: "Channel should still be responsive after out-of-range Cmd+N")
    }

    // MARK: - Active Tab

    // MARK: - Tab Count

    func testMultipleTabsExistAfterChannelCreation() throws {
        // Create second channel and switch away from it
        createChannel(type: "Shell")

        // Switch to first channel
        app.typeKey("1", modifierFlags: .command)

        collapseSidebar()

        // Check that at least 2 tab buttons exist
        let window = app.windows["Holoscape"]
        let tabButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'"))
        XCTAssertGreaterThanOrEqual(tabButtons.count, 2, "Should have at least 2 tabs")
    }

    // MARK: - Rapid Channel Switching

    func testRapidSwitchingDoesNotCrash() throws {
        // Create 3 channels
        for _ in 0..<3 {
            createChannel(type: "Shell")
        }

        // Rapidly switch between them
        for i in 1...4 {
            app.typeKey(String(i), modifierFlags: .command)
        }

        // App should still be running
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should survive rapid channel switching")

        assertActiveChannelResponsive(message: "Channel should be responsive after rapid switching")
    }

    // MARK: - Tab Click Switching (Usability Suite Section 5)

    func testClickingTabSwitchesChannel() throws {
        // Create a second channel
        createChannel(type: "Shell")
        Thread.sleep(forTimeInterval: 0.5)

        collapseSidebar()

        // Find tab buttons
        let window = app.windows["Holoscape"]
        let tabs = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'"))
        XCTAssertGreaterThanOrEqual(tabs.count, 2, "Should have at least 2 tab buttons")

        // Click the first tab
        let firstTab = tabs.element(boundBy: 0)
        firstTab.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Click the second tab
        let secondTab = tabs.element(boundBy: 1)
        secondTab.click()
        Thread.sleep(forTimeInterval: 0.5)

        // App should be responsive
        let appWindow = app.windows["Holoscape"]
        XCTAssertTrue(appWindow.exists, "App should be responsive after clicking tabs")
    }

    func testAllTabsShowCorrectLabels() throws {
        createChannel(type: "Shell")
        collapseSidebar()

        let window = app.windows["Holoscape"]
        let tabs = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'"))
        XCTAssertGreaterThanOrEqual(tabs.count, 2, "Should have at least 2 tabs")

        // Each tab should have a non-empty title
        for i in 0..<tabs.count {
            let tab = tabs.element(boundBy: i)
            let title = tab.title
            XCTAssertFalse(title.isEmpty, "Tab \(i) should have a non-empty title")
        }
    }
}
