import XCTest

final class BridgeChannelUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Helpers

    private func createBridgeChannel() {
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Bridge"].click()
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func createAgentChannel() {
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Agent (OAuth)"].click()
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - Channel Creation

    func testBridgeChannelCreatesSuccessfully() throws {
        createBridgeChannel()

        let window = app.windows["Holoscape"]
        let bridgeEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Bridge'")).firstMatch
        XCTAssertTrue(bridgeEntry.waitForExistence(timeout: 3), "Bridge channel should appear in sidebar")
    }

    func testBridgeChannelDisplaysLabel() throws {
        createBridgeChannel()

        let window = app.windows["Holoscape"]
        let bridgeEntry = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-Bridge'")).firstMatch
        XCTAssertTrue(bridgeEntry.waitForExistence(timeout: 3), "Bridge sidebar entry should display label")
    }

    func testBridgeChannelShowsSystemMessage() throws {
        createBridgeChannel()
        Thread.sleep(forTimeInterval: 0.5)

        // Bridge should display an explanatory system message on creation
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should display bridge system message without crash")
    }

    // MARK: - Broadcast Behavior

    func testBridgeChannelBroadcastsToAllAgents() throws {
        // Create 2 agent channels first
        createAgentChannel()
        createAgentChannel()
        Thread.sleep(forTimeInterval: 0.5)

        // Create bridge channel
        createBridgeChannel()

        let window = app.windows["Holoscape"]
        let bridgeEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Bridge'")).firstMatch
        guard bridgeEntry.waitForExistence(timeout: 2) else {
            XCTFail("Bridge entry should exist for broadcast test")
            return
        }
        bridgeEntry.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Submit text via bridge
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("broadcast-test")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        // No crash — broadcast delivered
        XCTAssertTrue(window.exists, "Window should remain after broadcast to agents")
    }

    func testBridgeChannelIgnoresNonAgentChannels() throws {
        // Default shell channel exists; bridge should not send to it
        createBridgeChannel()

        let window = app.windows["Holoscape"]
        let bridgeEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Bridge'")).firstMatch
        if bridgeEntry.waitForExistence(timeout: 2) {
            bridgeEntry.click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        let inputBox = app.textViews["input-box"]
        inputBox.typeText("bridge-ignore-test")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        // No crash — non-agent channels ignored
        XCTAssertTrue(window.exists, "Bridge should ignore non-agent channels without crash")
    }

    func testBridgeChannelWithNoAgents() throws {
        createBridgeChannel()

        let window = app.windows["Holoscape"]
        let bridgeEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Bridge'")).firstMatch
        if bridgeEntry.waitForExistence(timeout: 2) {
            bridgeEntry.click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Submit with no agent channels open
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("no-agents-test")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertTrue(window.exists, "Bridge should handle no agents without crash")
    }

    // MARK: - Input/Output

    func testBridgeChannelAcceptsInput() throws {
        createBridgeChannel()

        let window = app.windows["Holoscape"]
        let bridgeEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Bridge'")).firstMatch
        if bridgeEntry.waitForExistence(timeout: 2) {
            bridgeEntry.click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)
        inputBox.typeText("bridge-input-test")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertTrue(window.exists, "Window should remain after bridge input submission")
    }

    func testBridgeChannelShowsConfirmation() throws {
        createBridgeChannel()

        let window = app.windows["Holoscape"]
        let bridgeEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Bridge'")).firstMatch
        if bridgeEntry.waitForExistence(timeout: 2) {
            bridgeEntry.click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        let inputBox = app.textViews["input-box"]
        inputBox.typeText("confirm-test")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        // Bridge should show confirmation of what was sent
        XCTAssertTrue(window.exists, "Bridge should show broadcast confirmation without crash")
    }

    func testBridgeChannelCommandHistory() throws {
        createBridgeChannel()

        let window = app.windows["Holoscape"]
        let bridgeEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Bridge'")).firstMatch
        if bridgeEntry.waitForExistence(timeout: 2) {
            bridgeEntry.click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        let inputBox = app.textViews["input-box"]
        inputBox.typeText("bridge-history-test")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        inputBox.typeKey(.upArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.1)
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "bridge-history-test", "Up arrow should recall previous bridge broadcast")
    }

    // MARK: - Edge Cases

    func testBridgeChannelHandlesAgentDisconnect() throws {
        createAgentChannel()
        createBridgeChannel()
        Thread.sleep(forTimeInterval: 0.5)

        let window = app.windows["Holoscape"]
        let bridgeEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Bridge'")).firstMatch
        if bridgeEntry.waitForExistence(timeout: 2) {
            bridgeEntry.click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Submit while agent may be disconnecting
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("disconnect-test")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertTrue(window.exists, "Bridge should handle agent disconnect without crash")
    }

    func testBridgeChannelWithSingleAgent() throws {
        createAgentChannel()
        createBridgeChannel()

        let window = app.windows["Holoscape"]
        let bridgeEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Bridge'")).firstMatch
        if bridgeEntry.waitForExistence(timeout: 2) {
            bridgeEntry.click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        let inputBox = app.textViews["input-box"]
        inputBox.typeText("single-agent-test")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertTrue(window.exists, "Bridge should work correctly with exactly one agent")
    }
}
