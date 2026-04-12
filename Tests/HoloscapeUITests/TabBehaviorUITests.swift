import XCTest

final class TabBehaviorUITests: HoloscapeUITestCase {

    // MARK: - Labels Show Directory

    func testShellLabelShowsDirectoryNotShell() throws {
        try apiCreateChannel(dir: "/tmp", label: "tmp")
        Thread.sleep(forTimeInterval: 1)

        let entry = sidebarEntry("tmp")
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "Tab label should show directory name, not 'Shell'")
    }

    // MARK: - CD Updates Label

    func testCdUpdatesTabLabel() throws {
        // Get the default shell channel
        let channels = try apiListChannels()
        guard let label = channels.first?["label"] as? String else {
            XCTFail("No channels found")
            return
        }

        // Send cd /tmp — OSC 7 should update the tab label
        try apiSendInput(label: label, text: "cd /tmp\n")

        // Wait for the sidebar entry to update (OSC 7 triggers hostCurrentDirectoryUpdate)
        let tmpEntry = sidebarEntry("tmp")
        XCTAssertTrue(tmpEntry.waitForExistence(timeout: 5), "Tab label should update to 'tmp' after cd")
    }

    func testCdToAnotherDirectoryUpdatesLabel() throws {
        let channels = try apiListChannels()
        guard let label = channels.first?["label"] as? String else {
            XCTFail("No channels found")
            return
        }

        try apiSendInput(label: label, text: "cd /var\n")

        let varEntry = sidebarEntry("var")
        XCTAssertTrue(varEntry.waitForExistence(timeout: 5), "Tab label should update to 'var' after cd")
    }

    // MARK: - Persistence Across Restart

    func testLabelsPeristAcrossRestart() throws {
        // Channel state persistence is disabled under --ui-testing unless
        // --restore-channels is ALSO passed (see MainWindowController.scheduleSaveState
        // and AppDelegate.applicationWillTerminate). Relaunch with --restore-channels
        // so the save/restore cycle actually runs for this test.
        app.terminate()
        let notRunning = NSPredicate(format: "state == %d", XCUIApplication.State.notRunning.rawValue)
        expectation(for: notRunning, evaluatedWith: app, handler: nil)
        waitForExpectations(timeout: 5)

        app.launchArguments.append("--restore-channels")
        app.launch()
        let window = app.windows["Holoscape"]
        _ = window.waitForExistence(timeout: 10)
        let sidebar = window.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'sidebar-'")
        ).firstMatch
        _ = sidebar.waitForExistence(timeout: 10)

        try apiCreateChannel(dir: "/tmp", label: "persist-test")
        let entry = sidebarEntry("persist-test")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))

        // Wait out the 1s debounce in scheduleSaveState + margin before terminating
        Thread.sleep(forTimeInterval: 1.5)

        restartApp()

        let restored = sidebarEntry("persist-test")
        XCTAssertTrue(restored.waitForExistence(timeout: 5), "Channel label should persist across restart")
    }

    // MARK: - Close Channel

    func testCmdWClosesChannel() throws {
        try apiCreateChannel(label: "close-test")
        let entry = sidebarEntry("close-test")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))

        // Switch to the new channel first
        try apiSwitchChannel(label: "close-test")
        Thread.sleep(forTimeInterval: 0.5)

        // Close with Cmd+W
        app.typeKey("w", modifierFlags: .command)

        // Handle confirmation dialog if present
        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 1) {
            closeButton.click()
        }

        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: entry, handler: nil)
        waitForExpectations(timeout: 3)
    }

    // MARK: - Tab Ordering

    func testNoReorderOnBackgroundOutput() throws {
        // Create a second channel
        try apiCreateChannel(label: "bg-output")
        Thread.sleep(forTimeInterval: 1)

        // Switch to first channel
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        let countBefore = sidebarEntryCount()

        // Send output to the background channel
        try apiSendInput(label: "bg-output", text: "echo background-noise\n")
        Thread.sleep(forTimeInterval: 1)

        let countAfter = sidebarEntryCount()
        XCTAssertEqual(countAfter, countBefore, "Tab count should not change from background output")

        // Both entries should still exist
        let bgEntry = sidebarEntry("bg-output")
        XCTAssertTrue(bgEntry.exists, "Background channel should still be in sidebar")
    }
}
