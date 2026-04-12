import XCTest

final class DirectoryPersistenceUITests: HoloscapeUITestCase {

    private var testConfigDir: String?

    /// Override setUp to give each test an isolated config directory and
    /// enable channel persistence from the *first* launch. The base class
    /// appends --ui-testing but not --restore-channels, and the save guard
    /// in MainWindowController / AppDelegate skips persistence under
    /// --ui-testing unless --restore-channels is also present. Without this
    /// override, `cd /tmp` on the first launch never makes it to disk, and
    /// the restart tests have nothing to restore.
    override func setUpWithError() throws {
        continueAfterFailure = false
        let apiPort = UInt16.random(in: 49152...60999)
        Self.currentAPIBase = "http://127.0.0.1:\(apiPort)"

        let dir = "/tmp/holoscape-test-config-\(apiPort)"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        testConfigDir = dir

        app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launchArguments += ["--api-port", "\(apiPort)"]
        app.launchArguments.append("--restore-channels")
        app.launchEnvironment["HOLOSCAPE_CONFIG_DIR"] = dir
        app.launch()

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "App window should appear after launch")
        XCTAssertTrue(ensureSidebarVisible(), "Sidebar should be visible after launch")
    }

    override func tearDownWithError() throws {
        app.terminate()
        if let dir = testConfigDir {
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    // MARK: - CD Changes Label

    func testCdChangesLabelToDirectoryName() throws {
        let channels = try apiListChannels()
        guard let channelRef = (channels.first?["id"] as? String) ?? (channels.first?["label"] as? String) else {
            XCTFail("No channels found")
            return
        }
        XCTAssertTrue(firstSidebarEntry().waitForExistence(timeout: 3), "Default shell entry should exist")

        try apiSendInput(channelRef: channelRef, text: "cd /tmp\n")

        XCTAssertTrue(waitForFirstSidebarEntry(toContain: "tmp", timeout: 5), "Tab label should change to 'tmp' after cd")
    }

    // MARK: - Persist Across Restart

    func testDirectoryPersistsAcrossRestart() throws {
        let channels = try apiListChannels()
        guard let channelRef = (channels.first?["id"] as? String) ?? (channels.first?["label"] as? String) else {
            XCTFail("No channels found")
            return
        }
        XCTAssertTrue(firstSidebarEntry().waitForExistence(timeout: 3), "Default shell entry should exist")

        // cd to /tmp and wait for label update
        try apiSendInput(channelRef: channelRef, text: "cd /tmp\n")
        XCTAssertTrue(waitForFirstSidebarEntry(toContain: "tmp", timeout: 5), "Label should update to 'tmp'")

        // Let the 1s debounced saveState() flush to disk before restarting
        Thread.sleep(forTimeInterval: 1.5)

        // Quit and reopen — use restartApp() to wait for full process exit.
        // --restore-channels and HOLOSCAPE_CONFIG_DIR are already set from setUp.
        restartApp()

        let restoredEntry = sidebarEntry("tmp")
        XCTAssertTrue(restoredEntry.waitForExistence(timeout: 5), "Tab label 'tmp' should persist after restart")
    }

    func testRestoredChannelStartsInSavedDirectory() throws {
        let channels = try apiListChannels()
        guard let channelRef = (channels.first?["id"] as? String) ?? (channels.first?["label"] as? String) else {
            XCTFail("No channels found")
            return
        }
        XCTAssertTrue(firstSidebarEntry().waitForExistence(timeout: 3), "Default shell entry should exist")

        // cd to /tmp
        try apiSendInput(channelRef: channelRef, text: "cd /tmp\n")
        XCTAssertTrue(waitForFirstSidebarEntry(toContain: "tmp", timeout: 5))

        // Let the 1s debounced saveState() flush to disk before restarting
        Thread.sleep(forTimeInterval: 1.5)

        // Quit and reopen — use restartApp() to wait for full process exit.
        // --restore-channels and HOLOSCAPE_CONFIG_DIR are already set from setUp.
        restartApp()

        // Wait for restoration
        let restored = sidebarEntry("tmp")
        XCTAssertTrue(restored.waitForExistence(timeout: 5))

        // Verify the working directory by running pwd. Explicitly switch to
        // the restored channel first (matches testAPIChannelLifecycle pattern).
        try apiSwitchChannel(label: "tmp")
        Thread.sleep(forTimeInterval: 1)
        try apiSendInput(label: "tmp", text: "pwd")

        // macOS symlinks /tmp to /private/tmp
        let found = try waitForAPIOutput(label: "tmp", containing: "tmp", timeout: 10)
        XCTAssertTrue(found, "Restored channel should start in the saved directory")
    }
}
