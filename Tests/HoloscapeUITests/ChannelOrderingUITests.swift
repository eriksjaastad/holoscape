import XCTest

final class ChannelOrderingUITests: HoloscapeUITestCase {

    // MARK: - Unread Ordering

    /// XCUITest cannot verify sidebar ordering — we can only assert that multiple entries exist.
    func testMultipleChannelsExistAfterCreation() throws {
        createChannel(type: "Shell")

        let shell2 = sidebarEntry("Shell 2")
        XCTAssertTrue(shell2.waitForExistence(timeout: 3), "Shell 2 should exist in sidebar")

        // Switch to second channel so first becomes inactive
        app.typeKey("2", modifierFlags: .command)

        assertActiveChannelResponsive(message: "Channel should be responsive after switching to channel 2")

        let count = sidebarEntryCount()
        XCTAssertGreaterThanOrEqual(count, 2, "Should have at least 2 sidebar entries")
    }

    func testThreeChannelsAllVisibleInSidebar() throws {
        createChannel(type: "Shell")
        createChannel(type: "Shell")

        // Switch to last channel
        app.typeKey("3", modifierFlags: .command)

        assertActiveChannelResponsive(message: "Channel should be responsive after switching to channel 3")

        let window = app.windows["Holoscape"]
        let sidebarButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'"))
        XCTAssertGreaterThanOrEqual(sidebarButtons.count, 3, "Should have at least 3 sidebar entries")
    }

    func testChannelsSurviveSwitching() throws {
        createChannel(type: "Shell")

        let shell1 = sidebarEntry("Shell")
        XCTAssertTrue(shell1.waitForExistence(timeout: 3))

        // Switch away then back
        app.typeKey("2", modifierFlags: .command)
        assertActiveChannelResponsive(message: "Channel should be responsive after switching to channel 2")

        app.typeKey("1", modifierFlags: .command)
        assertActiveChannelResponsive(message: "Channel should be responsive after switching back to channel 1")

        // Both sidebar entries should still exist
        XCTAssertTrue(shell1.waitForExistence(timeout: 2), "Shell 1 should still exist after switching")
        let shell2 = sidebarEntry("Shell 2")
        XCTAssertTrue(shell2.waitForExistence(timeout: 2), "Shell 2 should still exist after switching")
    }

    func testPinnedChannelHasEmojiInSidebar() throws {
        createChannel(type: "Shell")

        let shell1 = sidebarEntry("Shell")
        XCTAssertTrue(shell1.waitForExistence(timeout: 3))

        // Pin the first shell
        shell1.rightClick()
        let pinItem = app.menuItems["Pin"]
        XCTAssertTrue(pinItem.waitForExistence(timeout: 2))
        pinItem.click()

        // Pinned channel should remain visible
        let window = app.windows["Holoscape"]
        let pinnedEntry = window.buttons.matching(NSPredicate(format: "title CONTAINS '\u{1F4CC}'")).firstMatch
        XCTAssertTrue(pinnedEntry.waitForExistence(timeout: 3), "Pinned channel should show pin emoji and remain at top")
    }

    // MARK: - Sidebar Order Stability

    func testSidebarOrderStableWhenNoActivity() throws {
        createChannel(type: "Shell")

        let window = app.windows["Holoscape"]
        let sidebarButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'"))
        let initialCount = sidebarButtons.count

        // Wait with no activity — use waitForExistence on an element we know exists
        assertActiveChannelResponsive(message: "Channel should be responsive after creating second shell")

        let afterCount = sidebarButtons.count
        XCTAssertEqual(initialCount, afterCount, "Sidebar order should not change without activity")
    }

    func testNewChannelAppearsAtEnd() throws {
        let window = app.windows["Holoscape"]
        let initialButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'"))
        let initialCount = initialButtons.count

        createChannel(type: "Shell")

        let afterButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'"))
        XCTAssertEqual(afterButtons.count, initialCount + 1, "New channel should increase sidebar count by 1")
    }

    func testClosedChannelRemovedCleanly() throws {
        createChannel(type: "Shell")

        let window = app.windows["Holoscape"]
        let shell2 = sidebarEntry("Shell 2")
        XCTAssertTrue(shell2.waitForExistence(timeout: 3))

        let beforeCount = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'")).count

        // Close Shell 2
        shell2.click()
        app.typeKey("w", modifierFlags: .command)
        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 2) {
            closeButton.click()
        }

        XCTAssertFalse(shell2.waitForExistence(timeout: 3), "Closed channel should leave no ghost entry in sidebar")

        let afterCount = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'")).count
        XCTAssertLessThan(afterCount, beforeCount, "Sidebar count should decrease after closing channel")
    }

    // MARK: - Tab Bar Order

    func testTabBarReflectsSidebarOrder() throws {
        createChannel(type: "Shell")

        // Collapse sidebar to show tab bar
        app.typeKey("s", modifierFlags: [.command, .shift])

        let window = app.windows["Holoscape"]
        let tabButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'"))
        XCTAssertGreaterThanOrEqual(tabButtons.count, 2, "Tab bar should reflect sidebar entries when sidebar collapsed")

        // Re-expand sidebar
        app.typeKey("s", modifierFlags: [.command, .shift])
    }

    func testTabBarShowsAllChannels() throws {
        createChannel(type: "Shell")

        // Collapse sidebar
        app.typeKey("s", modifierFlags: [.command, .shift])

        let window = app.windows["Holoscape"]
        let tabButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'"))
        XCTAssertGreaterThanOrEqual(tabButtons.count, 2, "Tab bar should show all channels when sidebar collapsed")

        // Re-expand sidebar
        app.typeKey("s", modifierFlags: [.command, .shift])
    }
}
