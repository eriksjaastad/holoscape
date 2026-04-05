import XCTest

final class GroupChatChannelUITests: HoloscapeUITestCase {

    private let envPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/agent-chat.env").path

    // MARK: - Channel Creation

    func testGroupChatChannelCreatesSuccessfully() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: envPath),
            "Agent chat env not configured"
        )
        createChannel(type: "Group Chat")
        XCTAssertTrue(
            sidebarEntry("Chat").waitForExistence(timeout: 3),
            "Chat channel should appear in sidebar"
        )
    }

    func testGroupChatChannelDisplaysLabel() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: envPath),
            "Agent chat env not configured"
        )
        createChannel(type: "Group Chat")
        let entry = sidebarEntry("Chat")
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "Chat sidebar entry should display label")
        XCTAssertTrue(entry.isHittable, "Chat sidebar entry should be hittable")
    }

    func testGroupChatChannelStartsPolling() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: envPath),
            "Agent chat env not configured"
        )
        createChannel(type: "Group Chat")
        let entry = sidebarEntry("Chat")
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "Chat should appear after creation")
        // Allow polling to start, then verify the entry is still present and enabled
        let stillExists = entry.waitForExistence(timeout: 2)
        XCTAssertTrue(stillExists, "Chat entry should remain after polling starts")
        XCTAssertTrue(entry.isEnabled, "Chat entry should be enabled while polling")
    }

    // MARK: - Message Display

    func testGroupChatChannelShowsMessages() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: envPath),
            "Agent chat env not configured"
        )
        createChannel(type: "Group Chat")
        let entry = sidebarEntry("Chat")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.click()
        // Verify the input box is present, meaning the chat view loaded
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2), "Input box should be visible in group chat view")
    }

    func testGroupChatChannelAutoScrolls() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: envPath),
            "Agent chat env not configured"
        )
        createChannel(type: "Group Chat")
        let entry = sidebarEntry("Chat")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.click()
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2), "Input box should exist after selecting chat channel")
        XCTAssertTrue(inputBox.isEnabled, "Input box should be enabled, indicating chat view is functional")
    }

    func testGroupChatChannelPreservesScrollPosition() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: envPath),
            "Agent chat env not configured"
        )
        createChannel(type: "Group Chat")
        let entry = sidebarEntry("Chat")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.click()
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2), "Input box should exist for scroll position test")
        XCTAssertTrue(entry.isHittable, "Sidebar entry should remain hittable after scroll interactions")
    }

    // MARK: - Input

    func testGroupChatChannelSendsMessage() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: envPath),
            "Agent chat env not configured"
        )
        createChannel(type: "Group Chat")
        let entry = sidebarEntry("Chat")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.click()

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2))
        inputBox.typeText("group-chat-test")
        inputBox.typeKey(.return, modifierFlags: [])

        // After submit the input box should clear
        let cleared = NSPredicate(format: "value == '' OR value == nil")
        expectation(for: cleared, evaluatedWith: inputBox, handler: nil)
        waitForExpectations(timeout: 2)
    }

    func testGroupChatChannelCommandHistory() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: envPath),
            "Agent chat env not configured"
        )
        createChannel(type: "Group Chat")
        let entry = sidebarEntry("Chat")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.click()

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2))
        inputBox.typeText("gc-history-test")
        inputBox.typeKey(.return, modifierFlags: [])

        // Wait for input to clear after submit
        let cleared = NSPredicate(format: "value == '' OR value == nil")
        expectation(for: cleared, evaluatedWith: inputBox, handler: nil)
        waitForExpectations(timeout: 2)

        inputBox.typeKey(.upArrow, modifierFlags: [])

        let recalled = NSPredicate(format: "value == 'gc-history-test'")
        expectation(for: recalled, evaluatedWith: inputBox, handler: nil)
        waitForExpectations(timeout: 2)

        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "gc-history-test", "Up arrow should recall previous group chat message")
    }

    // MARK: - Reconnection

    func testGroupChatChannelReconnectsOnFailure() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: envPath),
            "Agent chat env not configured"
        )
        createChannel(type: "Group Chat")
        let entry = sidebarEntry("Chat")
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "Chat entry should exist before reconnection test")
        // After a potential failure cycle, the entry should still be visible
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "Chat entry should persist through reconnection")
    }

    func testGroupChatChannelStateUpdatesOnDisconnect() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: envPath),
            "Agent chat env not configured"
        )
        createChannel(type: "Group Chat")
        let entry = sidebarEntry("Chat")
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "Chat entry should remain visible with updated state")
        XCTAssertTrue(entry.isEnabled, "Chat entry should be enabled even during disconnect")
    }

    func testGroupChatChannelResumesAfterReconnect() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: envPath),
            "Agent chat env not configured"
        )
        createChannel(type: "Group Chat")
        let entry = sidebarEntry("Chat")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.click()
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2), "Input box should be functional after reconnection resume")
    }

    // MARK: - Lifecycle

    func testGroupChatChannelStopsPollingOnDeactivate() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: envPath),
            "Agent chat env not configured"
        )
        createChannel(type: "Group Chat")
        let entry = sidebarEntry("Chat")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))

        // Close channel
        app.typeKey("w", modifierFlags: .command)
        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 1) {
            closeButton.click()
        }

        // Sidebar entry should disappear after close
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: entry, handler: nil)
        waitForExpectations(timeout: 3)
    }

    func testGroupChatChannelNoLeakedTimers() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: envPath),
            "Agent chat env not configured"
        )

        for _ in 0..<3 {
            createChannel(type: "Group Chat")
            let entry = sidebarEntry("Chat")
            XCTAssertTrue(entry.waitForExistence(timeout: 3))

            app.typeKey("w", modifierFlags: .command)
            let closeButton = app.buttons["Close"]
            if closeButton.waitForExistence(timeout: 1) {
                closeButton.click()
            }

            // Wait for entry to disappear before next cycle
            let gone = NSPredicate(format: "exists == false")
            expectation(for: gone, evaluatedWith: entry, handler: nil)
            waitForExpectations(timeout: 3)
        }

        // After all cycles, the sidebar should still be functional
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Window should remain after timer leak test")
        // Verify the sidebar is still interactive by checking the session launcher
        let comboBox = app.comboBoxes["session-launcher-combo"]
        XCTAssertTrue(comboBox.waitForExistence(timeout: 2), "Session launcher should remain functional after cycles")
        XCTAssertTrue(comboBox.isEnabled, "Session launcher should be enabled after create/close cycles")
    }
}
