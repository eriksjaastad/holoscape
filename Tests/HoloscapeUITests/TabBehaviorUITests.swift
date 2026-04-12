import XCTest

final class TabBehaviorUITests: HoloscapeUITestCase {

    // MARK: - Labels Show Directory

    func testShellLabelShowsDirectoryNotShell() throws {
        let countBefore = sidebarEntryCount()
        try apiCreateChannel(dir: "/tmp", label: "tmp")
        let entry = waitForNewSidebarEntry(expectedCount: countBefore + 1)
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "New shell tab should appear in sidebar")
        XCTAssertTrue(
            entry.identifier.contains("sidebar-tmp") || entry.label.contains("tmp"),
            "Tab label should show directory name 'tmp', got identifier='\(entry.identifier)' label='\(entry.label)'"
        )
    }

    // MARK: - CD Updates Label

    func testCdUpdatesTabLabel() throws {
        // Get the default shell channel
        let channels = try apiListChannels()
        guard let channelRef = (channels.first?["id"] as? String) ?? (channels.first?["label"] as? String) else {
            XCTFail("No channels found")
            return
        }
        XCTAssertTrue(firstSidebarEntry().waitForExistence(timeout: 3), "Default shell entry should exist")

        // Send cd /tmp — OSC 7 should update the tab label
        try apiSendInput(channelRef: channelRef, text: "cd /tmp\n")

        XCTAssertTrue(waitForFirstSidebarEntry(toContain: "tmp", timeout: 5), "Tab label should update to 'tmp' after cd")
    }

    func testCdToAnotherDirectoryUpdatesLabel() throws {
        let channels = try apiListChannels()
        guard let channelRef = (channels.first?["id"] as? String) ?? (channels.first?["label"] as? String) else {
            XCTFail("No channels found")
            return
        }
        XCTAssertTrue(firstSidebarEntry().waitForExistence(timeout: 3), "Default shell entry should exist")

        try apiSendInput(channelRef: channelRef, text: "cd /var\n")

        XCTAssertTrue(waitForFirstSidebarEntry(toContain: "var", timeout: 5), "Tab label should update to 'var' after cd")
    }

    // MARK: - Persistence Across Restart

    func testLabelsPeristAcrossRestart() throws {
        // Channel state persistence is disabled under --ui-testing unless
        // --restore-channels is ALSO passed (see MainWindowController.scheduleSaveState
        // and AppDelegate.applicationWillTerminate). Relaunch with --restore-channels
        // so the save/restore cycle actually runs for this test.
        //
        // TODO: This two-restart dance predates HOLOSCAPE_CONFIG_DIR. A cleaner
        // pattern — per-test config directory + --restore-channels from the
        // first launch — is used in DirectoryPersistenceUITests.setUpWithError
        // and should be lifted into the base class so tests like this one can
        // opt in via a single override instead of hand-rolling the restart.
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
