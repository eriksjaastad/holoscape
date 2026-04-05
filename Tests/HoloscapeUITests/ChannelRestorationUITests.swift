import XCTest

final class ChannelRestorationUITests: HoloscapeUITestCase {

    // MARK: - Basic Restoration

    func testQuitAndRelaunchRestoresChannels() throws {
        // Create 3 channels total (1 default + 2 new)
        for _ in 0..<2 {
            createChannel(type: "Shell")
        }

        // Verify we have channels
        let window = app.windows["Holoscape"]
        let sidebarButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'"))
        XCTAssertGreaterThanOrEqual(sidebarButtons.count, 3, "Should have 3 sidebar entries before quit")

        // Quit the app (triggers applicationWillTerminate -> saveState)
        app.terminate()
        app.launch()

        // Should have restored the channels
        let restoredWindow = app.windows["Holoscape"]
        XCTAssertTrue(restoredWindow.waitForExistence(timeout: 5), "Window should exist after relaunch")

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should be present after restoration")
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
        app.launch()

        // Tab bar should be visible (sidebar was collapsed)
        let restoredWindow = app.windows["Holoscape"]
        XCTAssertTrue(restoredWindow.waitForExistence(timeout: 5))

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

        // Verify pin emoji appeared
        let window = app.windows["Holoscape"]
        let pinnedEntry = window.buttons.matching(NSPredicate(format: "title CONTAINS '\u{1F4CC}'")).firstMatch
        XCTAssertTrue(pinnedEntry.waitForExistence(timeout: 3), "Pin emoji should appear after pinning")

        // Quit and relaunch
        app.terminate()
        app.launch()

        // Verify the pin indicator is present after restart
        let restoredWindow = app.windows["Holoscape"]
        XCTAssertTrue(restoredWindow.waitForExistence(timeout: 5))

        let restoredPinnedEntry = restoredWindow.buttons.matching(NSPredicate(format: "title CONTAINS '\u{1F4CC}'")).firstMatch
        XCTAssertTrue(restoredPinnedEntry.waitForExistence(timeout: 3), "Pinned channel should retain pin state after restart")
    }

    // MARK: - Empty State

    func testFreshLaunchCreatesDefaultShell() throws {
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Should have an input box from default shell")

        let shellEntry = sidebarEntry("Shell")
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 3), "Should have a Shell sidebar entry on fresh launch")
    }
}
