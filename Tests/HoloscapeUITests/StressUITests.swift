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

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should still be functional after stress test")
    }

    func testRapidSplitCloseClose50Cycles() throws {
        for _ in 0..<50 {
            app.typeKey("d", modifierFlags: .command)
            app.typeKey("w", modifierFlags: [.command, .shift])
        }

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should be functional after 50 split/close cycles")
    }

    func testRapidSettingsOpenClose50Cycles() throws {
        for _ in 0..<50 {
            app.typeKey(",", modifierFlags: .command)

            let settingsWindow = app.windows["Appearance Settings"]
            if settingsWindow.waitForExistence(timeout: 2) {
                settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
            }
        }

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should be functional after 50 settings open/close cycles")
    }

    func testRapidSidebarToggle100Cycles() throws {
        for _ in 0..<100 {
            app.typeKey("s", modifierFlags: [.command, .shift])
        }

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should be functional after 100 sidebar toggles")
    }

    func testRapidSearchOpenClose100Cycles() throws {
        for _ in 0..<100 {
            app.typeKey("f", modifierFlags: .command)
            app.typeKey(.escape, modifierFlags: [])
        }

        // Verify focus returns to input
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))
        inputBox.typeText("post-stress")
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "post-stress", "Input focus should be correct after stress")
    }

    // MARK: - Channel Accumulation

    func testCreate20ChannelsNoCrash() throws {
        for _ in 0..<19 {
            createChannel(type: "Shell")
        }

        // Switching should remain responsive
        app.typeKey("1", modifierFlags: .command)
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))

        app.typeKey("5", modifierFlags: .command)
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))

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

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should be functional after closing all channels")
    }

    // MARK: - Input Stress

    func testSubmit50Commands() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))

        for i in 0..<50 {
            inputBox.typeText("cmd-\(i)")
            inputBox.typeKey(.return, modifierFlags: [])
        }

        // Press up arrow to recall a command
        inputBox.typeKey(.upArrow, modifierFlags: [])
        let value = inputBox.value as? String ?? ""
        XCTAssertFalse(value.isEmpty, "Up arrow should recall a previously submitted command")
    }

    func testCommandHistory100Entries() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))

        for i in 0..<100 {
            inputBox.typeText("hist-\(i)")
            inputBox.typeKey(.return, modifierFlags: [])
        }

        // Navigate up through history
        for _ in 0..<50 {
            inputBox.typeKey(.upArrow, modifierFlags: [])
        }

        let value = inputBox.value as? String ?? ""
        XCTAssertFalse(value.isEmpty, "Should recall a history entry after up-arrow navigation")
    }

    func testPasteLargeInput() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))

        let largeText = String(repeating: "abcdefghij", count: 1000)

        // Use NSPasteboard to set clipboard, then Cmd+V to paste
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(largeText, forType: .string)

        inputBox.typeKey("v", modifierFlags: .command)

        let value = inputBox.value as? String ?? ""
        XCTAssertGreaterThan(value.count, 100, "Input box should contain substantial text after pasting large input")
    }

    // MARK: - Long-Running

    func testChannelEntryPersistsInSidebar() throws {
        let window = app.windows["Holoscape"]
        let shellEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Shell'")).firstMatch
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 3))

        // Wait 3 seconds and verify channel is still alive
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))
        inputBox.typeText("still-alive")

        // Wait by polling for the sidebar entry to still exist
        let stillExists = shellEntry.waitForExistence(timeout: 3)
        XCTAssertTrue(stillExists, "Shell sidebar entry should still exist after 3 second wait")
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
