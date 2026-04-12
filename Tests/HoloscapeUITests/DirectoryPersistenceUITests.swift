import XCTest

final class DirectoryPersistenceUITests: HoloscapeUITestCase {

    // MARK: - CD Changes Label

    func testCdChangesLabelToDirectoryName() throws {
        let channels = try apiListChannels()
        guard let channelRef = (channels.first?["id"] as? String) ?? (channels.first?["label"] as? String) else {
            XCTFail("No channels found")
            return
        }

        try apiSendInput(channelRef: channelRef, text: "cd /tmp\n")

        let tmpEntry = sidebarEntry("tmp")
        XCTAssertTrue(tmpEntry.waitForExistence(timeout: 5), "Tab label should change to 'tmp' after cd")
    }

    // MARK: - Persist Across Restart

    func testDirectoryPersistsAcrossRestart() throws {
        let channels = try apiListChannels()
        guard let channelRef = (channels.first?["id"] as? String) ?? (channels.first?["label"] as? String) else {
            XCTFail("No channels found")
            return
        }

        // cd to /tmp and wait for label update
        try apiSendInput(channelRef: channelRef, text: "cd /tmp\n")
        let tmpEntry = sidebarEntry("tmp")
        XCTAssertTrue(tmpEntry.waitForExistence(timeout: 5), "Label should update to 'tmp'")

        if !app.launchArguments.contains("--restore-channels") {
            app.launchArguments.append("--restore-channels")
        }

        // Quit and reopen — use restartApp() to wait for full process exit
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

        // cd to /tmp
        try apiSendInput(channelRef: channelRef, text: "cd /tmp\n")
        let tmpEntry = sidebarEntry("tmp")
        XCTAssertTrue(tmpEntry.waitForExistence(timeout: 5))

        if !app.launchArguments.contains("--restore-channels") {
            app.launchArguments.append("--restore-channels")
        }

        // Quit and reopen — use restartApp() to wait for full process exit
        restartApp()

        // Wait for restoration
        let restored = sidebarEntry("tmp")
        XCTAssertTrue(restored.waitForExistence(timeout: 5))

        // Verify the working directory by running pwd
        Thread.sleep(forTimeInterval: 1)
        try apiSendInput(label: "tmp", text: "pwd\n")

        // macOS symlinks /tmp to /private/tmp
        let found = try waitForAPIOutput(label: "tmp", containing: "tmp", timeout: 5)
        XCTAssertTrue(found, "Restored channel should start in the saved directory")
    }
}
