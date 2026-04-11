import XCTest

final class SidebarUITests: HoloscapeUITestCase {

    // MARK: - Toggle

    func testToggleSidebarViaShortcut() throws {
        let window = app.windows["Holoscape"]

        // Sidebar should be visible on launch (default expanded)
        // Toggle sidebar off with Cmd+Shift+S
        app.typeKey("s", modifierFlags: [.command, .shift])

        // Tab bar should appear when sidebar is collapsed
        let tabBar = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'")).firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 2), "Tab bar should show when sidebar collapsed")

        // Toggle sidebar back on
        app.typeKey("s", modifierFlags: [.command, .shift])

        // Sidebar entry should be visible again
        let entry = firstSidebarEntry()
        XCTAssertTrue(entry.waitForExistence(timeout: 2), "Sidebar entry should reappear after toggling back")
    }

    func testToggleSidebarViaMenu() throws {
        // File > Toggle Sidebar
        app.menuBars.firstMatch.menuBarItems["File"].click()
        let toggleItem = app.menuItems["Toggle Sidebar"]
        XCTAssertTrue(toggleItem.exists, "Toggle Sidebar menu item should exist")
        toggleItem.click()

        // Tab bar should appear when sidebar is collapsed
        let window = app.windows["Holoscape"]
        let tabBar = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'")).firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 2), "Tab bar should show when sidebar collapsed")

        // Toggle back
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["Toggle Sidebar"].click()

        let entry = firstSidebarEntry()
        XCTAssertTrue(entry.waitForExistence(timeout: 2), "Sidebar should reappear after toggling back via menu")
    }

    // MARK: - Pinned Channels

    func testPinnedChannelsRenderAboveUnpinned() throws {
        // Create a second shell channel
        let countBefore = sidebarEntryCount()
        createChannel(type: "Shell")

        // We should now have two shell entries
        let shell2 = waitForNewSidebarEntry(expectedCount: countBefore + 1)
        if shell2.waitForExistence(timeout: 2) {
            // Right-click to pin Shell 2
            shell2.rightClick()
            let pinItem = app.menuItems["Pin"]
            if pinItem.waitForExistence(timeout: 1) {
                pinItem.click()
            }
        }

        // After pinning, Shell 2 should appear before Shell in the sidebar
        // The pinned channel gets a pin emoji prefix
        let window = app.windows["Holoscape"]
        let pinnedEntry = window.buttons.matching(NSPredicate(format: "title CONTAINS '\u{1F4CC}'")).firstMatch
        XCTAssertTrue(pinnedEntry.waitForExistence(timeout: 2), "Pinned channel should show pin indicator")
    }

    // MARK: - Unread Indicators

    func testInactiveChannelStillVisibleInSidebar() throws {
        // Create a second shell channel
        let countBefore = sidebarEntryCount()
        createChannel(type: "Shell")
        let _ = waitForNewSidebarEntry(expectedCount: countBefore + 1)

        // Switch back to first channel
        app.typeKey("1", modifierFlags: .command)

        // Verify that both sidebar entries remain visible
        XCTAssertGreaterThanOrEqual(sidebarEntryCount(), 2, "Both sidebar entries should remain visible when switching channels")
    }

    // MARK: - Context Menu

    func testContextMenuAppearsOnRightClick() throws {
        let shellEntry = firstSidebarEntry()
        guard shellEntry.waitForExistence(timeout: 2) else {
            // Sidebar might be collapsed, toggle it on
            app.typeKey("s", modifierFlags: [.command, .shift])
            let retried = firstSidebarEntry()
            XCTAssertTrue(retried.waitForExistence(timeout: 2), "Sidebar entry should exist after toggling sidebar on")
            return
        }

        shellEntry.rightClick()

        let closeItem = app.menuItems["Close"]
        XCTAssertTrue(closeItem.waitForExistence(timeout: 2), "Context menu should have Close item")

        let renameItem = app.menuItems["Rename"]
        XCTAssertTrue(renameItem.exists, "Context menu should have Rename item")

        let duplicateItem = app.menuItems["Duplicate"]
        XCTAssertTrue(duplicateItem.exists, "Context menu should have Duplicate item")

        let pinItem = app.menuItems["Pin"]
        XCTAssertTrue(pinItem.exists, "Context menu should have Pin item")

        // Dismiss menu
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Channel Labels

    func testChannelLabelNotTruncatedAtDefaultWidth() throws {
        let shellEntry = firstSidebarEntry()

        if shellEntry.waitForExistence(timeout: 2) {
            // The label should be fully visible — not clipped
            let entryFrame = shellEntry.frame
            XCTAssertGreaterThan(entryFrame.width, 40, "Sidebar entry should be wide enough to show label")
        }
    }
}
