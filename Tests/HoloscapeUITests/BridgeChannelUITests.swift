import XCTest

final class BridgeChannelUITests: HoloscapeUITestCase {

    // MARK: - Channel Creation

    func testBridgeChannelCreatesSuccessfully() throws {
        createChannel(type: "Bridge")
        XCTAssertTrue(
            sidebarEntry("Bridge").waitForExistence(timeout: 3),
            "Bridge channel should appear in sidebar"
        )
    }

    func testBridgeChannelDisplaysLabel() throws {
        createChannel(type: "Bridge")
        let entry = sidebarEntry("Bridge")
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "Bridge sidebar entry should display label")
        XCTAssertTrue(entry.isHittable, "Bridge sidebar entry should be hittable")
    }

    // MARK: - Input/Output

    func testBridgeChannelAcceptsInput() throws {
        createChannel(type: "Bridge")
        let bridgeEntry = sidebarEntry("Bridge")
        XCTAssertTrue(bridgeEntry.waitForExistence(timeout: 3))
        bridgeEntry.click()

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2))
        inputBox.typeText("bridge-input-test")
        inputBox.typeKey(.return, modifierFlags: [])

        let cleared = NSPredicate(format: "value == '' OR value == nil")
        expectation(for: cleared, evaluatedWith: inputBox, handler: nil)
        waitForExpectations(timeout: 2)
    }

    func testBridgeChannelCommandHistory() throws {
        createChannel(type: "Bridge")
        let bridgeEntry = sidebarEntry("Bridge")
        XCTAssertTrue(bridgeEntry.waitForExistence(timeout: 3))
        bridgeEntry.click()

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2))
        inputBox.typeText("bridge-history-test")
        inputBox.typeKey(.return, modifierFlags: [])

        let cleared = NSPredicate(format: "value == '' OR value == nil")
        expectation(for: cleared, evaluatedWith: inputBox, handler: nil)
        waitForExpectations(timeout: 2)

        inputBox.typeKey(.upArrow, modifierFlags: [])

        let recalled = NSPredicate(format: "value == 'bridge-history-test'")
        expectation(for: recalled, evaluatedWith: inputBox, handler: nil)
        waitForExpectations(timeout: 2)

        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "bridge-history-test", "Up arrow should recall previous bridge broadcast")
    }

    // MARK: - Broadcast Behavior

    func testBridgeChannelBroadcastsToAllAgents() throws {
        try skipUnlessClaudeCLIInstalled()

        // Create 2 agent channels first
        createChannel(type: "Agent (OAuth)")
        XCTAssertTrue(sidebarEntry("Agent").waitForExistence(timeout: 3))
        createChannel(type: "Agent (OAuth)")

        // Create bridge channel
        createChannel(type: "Bridge")
        let bridgeEntry = sidebarEntry("Bridge")
        XCTAssertTrue(bridgeEntry.waitForExistence(timeout: 3))
        bridgeEntry.click()

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2))
        inputBox.typeText("broadcast-test")
        inputBox.typeKey(.return, modifierFlags: [])

        // After submit the input box should clear
        let cleared = NSPredicate(format: "value == '' OR value == nil")
        expectation(for: cleared, evaluatedWith: inputBox, handler: nil)
        waitForExpectations(timeout: 2)

        // Both agent sidebar entries should still exist
        XCTAssertGreaterThanOrEqual(
            sidebarEntryCount(), 3,
            "Both agent channels and bridge should still exist in sidebar after broadcast"
        )
    }

    func testBridgeChannelWithNoAgents() throws {
        // Submit text in bridge with no agent channels created
        createChannel(type: "Bridge")
        let bridgeEntry = sidebarEntry("Bridge")
        XCTAssertTrue(bridgeEntry.waitForExistence(timeout: 3))
        bridgeEntry.click()

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2))
        inputBox.typeText("no-agents-test")
        inputBox.typeKey(.return, modifierFlags: [])

        // Input should clear even with no agent targets — no crash
        let cleared = NSPredicate(format: "value == '' OR value == nil")
        expectation(for: cleared, evaluatedWith: inputBox, handler: nil)
        waitForExpectations(timeout: 2)

        // App should still be running with window present
        XCTAssertTrue(app.windows["Holoscape"].exists, "App should not crash when broadcasting with no agents")
    }

    func testBridgeChannelWithSingleAgent() throws {
        try skipUnlessClaudeCLIInstalled()

        createChannel(type: "Agent (OAuth)")
        XCTAssertTrue(sidebarEntry("Agent").waitForExistence(timeout: 3))

        createChannel(type: "Bridge")
        let bridgeEntry = sidebarEntry("Bridge")
        XCTAssertTrue(bridgeEntry.waitForExistence(timeout: 3))
        bridgeEntry.click()

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2))
        inputBox.typeText("single-agent-test")
        inputBox.typeKey(.return, modifierFlags: [])

        // Input should clear with exactly one agent target
        let cleared = NSPredicate(format: "value == '' OR value == nil")
        expectation(for: cleared, evaluatedWith: inputBox, handler: nil)
        waitForExpectations(timeout: 2)
    }

    func testBridgeChannelIgnoresNonAgentChannels() throws {
        throw XCTSkip("Cannot verify broadcast routing to specific channel types via XCUITest")
    }

    func testBridgeChannelHandlesAgentDisconnect() throws {
        throw XCTSkip("Cannot verify disconnect handling during broadcast via XCUITest")
    }

    func testBridgeChannelShowsConfirmation() throws {
        throw XCTSkip("Cannot verify bridge confirmation message content via XCUITest")
    }
}
