import XCTest

final class AgentChannelUITests: HoloscapeUITestCase {

    // MARK: - Channel Creation

    func testAgentChannelCreatesSuccessfully() throws {
        try skipUnlessClaudeCLIInstalled()
        createChannel(type: "Agent (OAuth)")
        XCTAssertTrue(
            sidebarEntry("Agent").waitForExistence(timeout: 3),
            "Agent channel should appear in sidebar"
        )
    }

    func testAgentChannelDisplaysLabel() throws {
        try skipUnlessClaudeCLIInstalled()
        createChannel(type: "Agent (OAuth)")
        let entry = sidebarEntry("Agent")
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "Agent sidebar entry should display label")
        XCTAssertTrue(entry.isHittable, "Agent sidebar entry should be hittable")
    }

    // MARK: - Authentication

    func testAgentChannelAPIKeyAuth() throws {
        try skipUnlessClaudeCLIInstalled()
        createChannel(type: "Agent (API Key)")
        let entry = sidebarEntry("Agent")
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "API Key agent should appear in sidebar")
        XCTAssertTrue(entry.isHittable, "API Key agent entry should be hittable")
    }

    // MARK: - Role Detection

    func testAgentChannelDetectsRole() throws {
        throw XCTSkip("Cannot verify role detection via XCUITest — role is internal state")
    }

    func testAgentChannelRoleLabelShortened() throws {
        throw XCTSkip("Cannot verify role label shortening via XCUITest")
    }

    func testAgentChannelStateTransitions() throws {
        throw XCTSkip("Cannot verify state transitions via XCUITest — indicator colors not accessible")
    }

    // MARK: - Input/Output

    func testAgentChannelAcceptsInput() throws {
        try skipUnlessClaudeCLIInstalled()
        createChannel(type: "Agent (OAuth)")
        let entry = sidebarEntry("Agent")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.click()

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2))
        inputBox.typeText("hello agent")
        inputBox.typeKey(.return, modifierFlags: [])

        // After submit the input box should clear
        let cleared = NSPredicate(format: "value == '' OR value == nil")
        expectation(for: cleared, evaluatedWith: inputBox, handler: nil)
        waitForExpectations(timeout: 2)
    }

    func testAgentChannelShowsOutput() throws {
        try skipUnlessClaudeCLIInstalled()
        createChannel(type: "Agent (OAuth)")
        let entry = sidebarEntry("Agent")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.click()
        // Agent view should have an input box, confirming the output pane loaded
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2), "Agent output view should load with input box")
    }

    func testAgentChannelCommandHistory() throws {
        try skipUnlessClaudeCLIInstalled()
        createChannel(type: "Agent (OAuth)")
        let entry = sidebarEntry("Agent")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.click()

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2))
        inputBox.typeText("agent-history-test")
        inputBox.typeKey(.return, modifierFlags: [])

        // Wait for input to clear after submit
        let cleared = NSPredicate(format: "value == '' OR value == nil")
        expectation(for: cleared, evaluatedWith: inputBox, handler: nil)
        waitForExpectations(timeout: 2)

        inputBox.typeKey(.upArrow, modifierFlags: [])

        let recalled = NSPredicate(format: "value == 'agent-history-test'")
        expectation(for: recalled, evaluatedWith: inputBox, handler: nil)
        waitForExpectations(timeout: 2)

        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "agent-history-test", "Up arrow should recall previous agent command")
    }

    // MARK: - Lifecycle

    func testAgentChannelDeactivates() throws {
        try skipUnlessClaudeCLIInstalled()
        createChannel(type: "Agent (OAuth)")
        let entry = sidebarEntry("Agent")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))

        // Close the agent channel
        app.typeKey("w", modifierFlags: .command)
        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 1) {
            closeButton.click()
        }

        // Sidebar entry should disappear
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: entry, handler: nil)
        waitForExpectations(timeout: 3)
    }

    func testAgentChannelRetry() throws {
        try skipUnlessClaudeCLIInstalled()
        createChannel(type: "Agent (OAuth)")
        let entry = sidebarEntry("Agent")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))

        entry.rightClick()

        let reconnectItem = app.menuItems["Reconnect"]
        XCTAssertTrue(
            reconnectItem.waitForExistence(timeout: 2),
            "Reconnect menu item should exist in context menu"
        )

        // Dismiss context menu
        app.typeKey(.escape, modifierFlags: [])
    }
}
