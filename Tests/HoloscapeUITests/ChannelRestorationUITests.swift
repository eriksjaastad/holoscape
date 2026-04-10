import XCTest

final class ChannelRestorationUITests: HoloscapeUITestCase {

    // MARK: - Basic Restoration

    func testQuitAndRelaunchRestoresChannels() throws {
        // Create 3 channels total (1 default + 2 new)
        for _ in 0..<2 {
            createChannel(type: "Shell")
        }

        // Verify we have channels
        XCTAssertGreaterThanOrEqual(sidebarEntryCount(), 3, "Should have 3 sidebar entries before quit")

        // Quit the app (triggers applicationWillTerminate -> saveState)
        app.terminate()
        app.launchArguments.append("--ui-testing")
        app.launchArguments.append("--restore-channels")
        app.launch()

        // Should have restored the channels
        let restoredWindow = app.windows["Holoscape"]
        XCTAssertTrue(restoredWindow.waitForExistence(timeout: 10), "Window should exist after relaunch")

        assertActiveChannelResponsive(message: "Channel should be responsive after restoration")

        XCTAssertGreaterThanOrEqual(sidebarEntryCount(), 3, "All 3 channels should be restored")
    }

    // MARK: - State Persistence

    func testSidebarCollapseStatePersistsAcrossRestart() throws {
        // Collapse sidebar
        app.typeKey("s", modifierFlags: [.command, .shift])

        // Verify tab bar appeared (sidebar collapsed)
        let window = app.windows["Holoscape"]
        let tabButton = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'")).firstMatch
        XCTAssertTrue(tabButton.waitForExistence(timeout: 3), "Tab bar should appear after collapsing sidebar")

        // Quit and relaunch
        app.terminate()
        app.launchArguments.append("--ui-testing")
        app.launchArguments.append("--restore-channels")
        app.launch()

        // Tab bar should be visible (sidebar was collapsed)
        let restoredWindow = app.windows["Holoscape"]
        XCTAssertTrue(restoredWindow.waitForExistence(timeout: 10))

        let restoredTabButton = restoredWindow.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'")).firstMatch
        XCTAssertTrue(restoredTabButton.waitForExistence(timeout: 3), "Tab bar should be visible if sidebar was collapsed before quit")

        // Restore sidebar for clean state
        app.typeKey("s", modifierFlags: [.command, .shift])
    }

    // MARK: - Pin State Persistence

    func testPinStatePersistsAcrossRestart() throws {
        // Create a second channel
        createChannel(type: "Shell")

        // Pin the second channel via context menu
        let shell2 = sidebarEntry("Shell 2")
        XCTAssertTrue(shell2.waitForExistence(timeout: 3))

        shell2.rightClick()
        let pinItem = app.menuItems["Pin"]
        XCTAssertTrue(pinItem.waitForExistence(timeout: 2))
        pinItem.click()

        // Verify pin emoji appeared in sidebar accessibility title
        let pinnedEntry = pinnedSidebarEntry("Shell 2")
        XCTAssertTrue(pinnedEntry.waitForExistence(timeout: 3), "Pin emoji should appear in sidebar entry identifier after pinning")

        // Quit and relaunch
        app.terminate()
        app.launch()

        // Verify the pin indicator is present after restart
        let restoredWindow = app.windows["Holoscape"]
        XCTAssertTrue(restoredWindow.waitForExistence(timeout: 5))

        let restoredPinnedEntry = pinnedSidebarEntry("Shell 2")
        XCTAssertTrue(restoredPinnedEntry.waitForExistence(timeout: 3), "Pinned channel should retain pin state after restart")
    }

    // MARK: - Empty State

    func testDefaultShellExistsOnLaunch() throws {
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        assertActiveChannelResponsive(message: "Default shell should be responsive on launch")

        let shellEntry = sidebarEntry("Shell")
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 3), "Should have a Shell sidebar entry on fresh launch")
    }
}
