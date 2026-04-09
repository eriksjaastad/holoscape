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

    // MARK: - Input/Output

    func testAgentChannelAcceptsInput() throws {
        try skipUnlessClaudeCLIInstalled()
        createChannel(type: "Agent (OAuth)")
        let entry = sidebarEntry("Agent")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.click()

        // Agent channels are PTY — they use terminal view, not input-box
        assertActiveChannelResponsive(message: "Agent channel should be responsive after creation")
    }

    func testAgentChannelViewLoads() throws {
        try skipUnlessClaudeCLIInstalled()
        createChannel(type: "Agent (OAuth)")
        let entry = sidebarEntry("Agent")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.click()

        // Agent channels are PTY — verify terminal view loads
        assertActiveChannelResponsive(message: "Agent view should load with terminal view")

        // Verify the output scroll view also exists
        let window = app.windows["Holoscape"]
        XCTAssertGreaterThanOrEqual(window.scrollViews.count, 1, "Agent view should have an output scroll view")
    }

    func testAgentChannelResponsiveAfterSwitch() throws {
        try skipUnlessClaudeCLIInstalled()
        createChannel(type: "Agent (OAuth)")
        let entry = sidebarEntry("Agent")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.click()

        // Agent channels are PTY — verify terminal is responsive
        assertActiveChannelResponsive(message: "Agent channel should be responsive after switching to it")
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
