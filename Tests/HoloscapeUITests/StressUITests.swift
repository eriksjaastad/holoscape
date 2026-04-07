import XCTest
import AppKit

final class StressUITests: HoloscapeUITestCase {

    // MARK: - Rapid Operations

    func testRapidChannelCreateClose100Cycles() throws {
        let window = app.windows["Holoscape"]

        for _ in 0..<100 {
            createChannel(type: "Shell")

            app.typeKey("w", modifierFlags: .command)
            let closeButton = app.buttons["Close"]
            if closeButton.waitForExistence(timeout: 1) {
                closeButton.click()
                // Wait for dialog to dismiss
                let dismissed = NSPredicate(format: "exists == false")
                expectation(for: dismissed, evaluatedWith: closeButton, handler: nil)
                waitForExpectations(timeout: 3)
            }
        }

        // Assert sidebar entry count at end — should have just the default shell
        let sidebarButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'"))
        XCTAssertGreaterThanOrEqual(sidebarButtons.count, 1, "App should have at least one sidebar entry after 100 create/close cycles")

        assertActiveChannelResponsive(message: "Channel should still be responsive after stress test")
    }

    func testRapidSplitCloseClose50Cycles() throws {
        for _ in 0..<50 {
            app.typeKey("d", modifierFlags: .command)
            app.typeKey("w", modifierFlags: [.command, .shift])
        }

        assertActiveChannelResponsive(message: "Channel should be responsive after 50 split/close cycles")
    }

    func testRapidSettingsOpenClose50Cycles() throws {
        for _ in 0..<50 {
            app.typeKey(",", modifierFlags: .command)

            let settingsWindow = app.windows["Appearance Settings"]
            if settingsWindow.waitForExistence(timeout: 2) {
                settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
            }
        }

        assertActiveChannelResponsive(message: "Channel should be responsive after 50 settings open/close cycles")
    }

    func testRapidSidebarToggle100Cycles() throws {
        for _ in 0..<100 {
            app.typeKey("s", modifierFlags: [.command, .shift])
        }

        assertActiveChannelResponsive(message: "Channel should be responsive after 100 sidebar toggles")
    }

    func testRapidSearchOpenClose100Cycles() throws {
        for _ in 0..<100 {
            app.typeKey("f", modifierFlags: .command)
            app.typeKey(.escape, modifierFlags: [])
        }

        // Verify the app is still responsive after rapid search toggling
        assertActiveChannelResponsive(message: "Channel should be responsive after 100 search open/close cycles")
    }

    // MARK: - Channel Accumulation

    func testCreate20ChannelsNoCrash() throws {
        for _ in 0..<19 {
            createChannel(type: "Shell")
        }

        // Switching should remain responsive
        app.typeKey("1", modifierFlags: .command)
        assertActiveChannelResponsive(message: "Channel 1 should be responsive with 20 channels open")

        app.typeKey("5", modifierFlags: .command)
        assertActiveChannelResponsive(message: "Channel 5 should be responsive with 20 channels open")

        let window = app.windows["Holoscape"]
        let sidebarButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'"))
        XCTAssertGreaterThanOrEqual(sidebarButtons.count, 20, "Should have 20 sidebar entries")
    }

    func testCreate20ChannelsThenCloseAll() throws {
        for _ in 0..<19 {
            createChannel(type: "Shell")
        }

        // Close all extra channels
        for _ in 0..<19 {
            app.typeKey("w", modifierFlags: .command)
            let closeButton = app.buttons["Close"]
            if closeButton.waitForExistence(timeout: 1) {
                closeButton.click()
            }
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 3), "Window should remain after closing all extra channels")

        assertActiveChannelResponsive(message: "Channel should be responsive after closing all extra channels")
    }

    // MARK: - Input Stress
    //
    // Shell channels type directly into the terminal PTY — there is no separate
    // input box (the input box is only for non-PTY channels like Group Chat).
    // These tests send commands via the HTTP API, which writes to the PTY directly.

    func testSubmit50Commands() throws {
        let channels = try apiListChannels()
        guard let label = channels.first?["label"] as? String else {
            XCTFail("No channels found")
            return
        }

        for i in 0..<50 {
            try apiSendInput(label: label, text: "echo cmd-\(i)\n")
        }

        // Verify the last command produced output
        let found = try waitForAPIOutput(label: label, containing: "cmd-49", timeout: 10)
        XCTAssertTrue(found, "All 50 commands should execute successfully")
    }

    func testCommandHistory100Entries() throws {
        let channels = try apiListChannels()
        guard let label = channels.first?["label"] as? String else {
            XCTFail("No channels found")
            return
        }

        for i in 0..<100 {
            try apiSendInput(label: label, text: "echo hist-\(i)\n")
        }

        // Verify output contains entries from throughout the run
        let foundEarly = try waitForAPIOutput(label: label, containing: "hist-10", timeout: 10)
        let foundLate = try waitForAPIOutput(label: label, containing: "hist-99", timeout: 5)
        XCTAssertTrue(foundEarly, "Early history entries should be in output")
        XCTAssertTrue(foundLate, "Late history entries should be in output")
    }

    func testPasteLargeInput() throws {
        let terminal = terminalView()
        XCTAssertTrue(terminal.waitForExistence(timeout: 3))
        terminal.click()

        let largeText = String(repeating: "a", count: 1000)

        // Use NSPasteboard to set clipboard, then Cmd+V to paste into terminal
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(largeText, forType: .string)

        app.typeKey("v", modifierFlags: .command)

        // App should not crash from large paste
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should handle large paste into terminal without crashing")
    }

    // MARK: - Long-Running

    func testChannelEntryPersistsInSidebar() throws {
        let window = app.windows["Holoscape"]
        let sidebarButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'"))
        XCTAssertGreaterThanOrEqual(sidebarButtons.count, 1, "Should have at least one sidebar entry")

        let firstEntry = sidebarButtons.firstMatch

        // Type into terminal to verify channel is alive
        let terminal = terminalView()
        if terminal.waitForExistence(timeout: 3) {
            terminal.click()
            app.typeText("echo still-alive\n")
        }

        // Verify sidebar entry persists
        let stillExists = firstEntry.waitForExistence(timeout: 3)
        XCTAssertTrue(stillExists, "Sidebar entry should still exist after activity")
    }

    // MARK: - Edge Case Tests (Usability Suite Section 10)

    func testSixPlusTabsAllVisibleInSidebar() throws {
        // Create 6 additional channels (7 total with default)
        for i in 1...6 {
            try apiCreateChannel(label: "edge-\(i)")
        }
        Thread.sleep(forTimeInterval: 1)

        let window = app.windows["Holoscape"]
        let sidebarButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'"))
        XCTAssertGreaterThanOrEqual(sidebarButtons.count, 7, "All 7+ tabs should be present in sidebar")
    }

    func testRapidAPISwitchingNoCrash() throws {
        try apiCreateChannel(label: "rapid-a")
        try apiCreateChannel(label: "rapid-b")
        try apiCreateChannel(label: "rapid-c")
        Thread.sleep(forTimeInterval: 0.5)

        for _ in 0..<10 {
            try apiSwitchChannel(label: "rapid-a")
            try apiSwitchChannel(label: "rapid-b")
            try apiSwitchChannel(label: "rapid-c")
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should survive rapid API-driven channel switching")
    }

    func testLongPathTruncatesGracefully() throws {
        let longName = String(repeating: "a", count: 80)
        let longPath = "/tmp/\(longName)"
        try apiCreateChannel(dir: longPath, label: longName)
        Thread.sleep(forTimeInterval: 1)

        let entry = sidebarEntry(longName)
        if entry.waitForExistence(timeout: 3) {
            // Sidebar width is ~220px — entry should not blow out the layout
            XCTAssertLessThanOrEqual(entry.frame.width, 300, "Long label should be constrained to sidebar width")
        }
        // Main assertion: app didn't crash
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should handle long directory paths gracefully")
    }

    func testCtrlCKeepsTabOpen() throws {
        try apiCreateChannel(dir: "/tmp", label: "ctrl-c-test")
        Thread.sleep(forTimeInterval: 1)

        // Start a long-running process
        try apiSendInput(label: "ctrl-c-test", text: "sleep 999\n")
        Thread.sleep(forTimeInterval: 0.5)

        // Send Ctrl+C (ETX character)
        try apiSendInput(label: "ctrl-c-test", text: "\u{03}")
        Thread.sleep(forTimeInterval: 0.5)

        // Channel should still exist in sidebar
        let entry = sidebarEntry("ctrl-c-test")
        XCTAssertTrue(entry.exists, "Tab should remain open after Ctrl+C")

        // State should not be disconnected
        let value = entry.value as? String
        XCTAssertNotEqual(value, "disconnected", "Channel should not be disconnected after Ctrl+C")
    }

    func testExitShowsDisconnectedState() throws {
        try apiCreateChannel(dir: "/tmp", label: "exit-test")
        let entry = sidebarEntry("exit-test")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 1)

        // Send exit to close the shell process
        try apiSendInput(label: "exit-test", text: "exit\n")
        Thread.sleep(forTimeInterval: 1)

        // Sidebar entry should show disconnected state
        let value = entry.value as? String
        XCTAssertEqual(value, "disconnected", "Tab should show 'disconnected' after shell exits")
    }
}
