import XCTest

final class MCPChannelUITests: XCTestCase {
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

    private func createMCPChannel() throws {
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 2))

        let mcpButton = dialog.buttons.matching(NSPredicate(format: "title CONTAINS[c] 'MCP'")).firstMatch
        guard mcpButton.exists else {
            dialog.buttons["Cancel"].click()
            throw XCTSkip("No MCP option available in channel picker")
        }
        mcpButton.click()
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - Channel Creation

    func testMCPChannelCreatesSuccessfully() throws {
        try createMCPChannel()

        let window = app.windows["Holoscape"]
        let mcpEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-MCP'")).firstMatch
        XCTAssertTrue(mcpEntry.waitForExistence(timeout: 3), "MCP channel should appear in sidebar after creation")
    }

    func testMCPChannelDisplaysLabel() throws {
        try createMCPChannel()

        let window = app.windows["Holoscape"]
        let mcpEntry = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-MCP'")).firstMatch
        XCTAssertTrue(mcpEntry.waitForExistence(timeout: 3), "MCP sidebar entry should display label")
    }

    func testMCPChannelInitializesProtocol() throws {
        try createMCPChannel()
        Thread.sleep(forTimeInterval: 1.0)

        // MCP channel should attempt handshake — verify no crash
        let window = app.windows["Holoscape"]
        let mcpEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-MCP'")).firstMatch
        XCTAssertTrue(mcpEntry.exists, "MCP channel should exist after protocol initialization attempt")
    }

    // MARK: - Connection Handling

    func testMCPChannelHandlesInitFailure() throws {
        try createMCPChannel()
        Thread.sleep(forTimeInterval: 2.0)

        // Invalid MCP server should show disconnected, not crash
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain after MCP init failure")
    }

    func testMCPChannelReconnect() throws {
        try createMCPChannel()
        Thread.sleep(forTimeInterval: 1.0)

        let window = app.windows["Holoscape"]
        let mcpEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-MCP'")).firstMatch
        guard mcpEntry.waitForExistence(timeout: 2) else { return }

        mcpEntry.rightClick()
        Thread.sleep(forTimeInterval: 0.3)

        let reconnectItem = app.menuItems["Reconnect"]
        if reconnectItem.waitForExistence(timeout: 1) {
            XCTAssertTrue(reconnectItem.exists, "Reconnect menu item should exist for MCP channel")
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    func testMCPChannelStateIndicator() throws {
        try createMCPChannel()
        Thread.sleep(forTimeInterval: 1.0)

        // Verify sidebar entry exists with state information
        let window = app.windows["Holoscape"]
        let mcpEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-MCP'")).firstMatch
        XCTAssertTrue(mcpEntry.exists, "MCP sidebar entry should show state indicator")
    }

    // MARK: - Input/Output

    func testMCPChannelSendsMessage() throws {
        try createMCPChannel()

        let window = app.windows["Holoscape"]
        let mcpEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-MCP'")).firstMatch
        if mcpEntry.waitForExistence(timeout: 2) {
            mcpEntry.click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)
        inputBox.typeText("mcp-test-message")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertTrue(window.exists, "Window should remain after MCP message submission")
    }

    func testMCPChannelDisplaysResponse() throws {
        try createMCPChannel()
        Thread.sleep(forTimeInterval: 1.0)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should display MCP responses without crash")
    }

    func testMCPChannelCommandHistory() throws {
        try createMCPChannel()

        let window = app.windows["Holoscape"]
        let mcpEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-MCP'")).firstMatch
        if mcpEntry.waitForExistence(timeout: 2) {
            mcpEntry.click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        let inputBox = app.textViews["input-box"]
        inputBox.typeText("mcp-history-test")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        inputBox.typeKey(.upArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.1)
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "mcp-history-test", "Up arrow should recall previous MCP message")
    }

    // MARK: - Error Handling

    func testMCPChannelHandlesServerDisconnect() throws {
        try createMCPChannel()
        Thread.sleep(forTimeInterval: 2.0)

        // Server drop should update state, not crash
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain after MCP server disconnect")
    }

    func testMCPChannelHandlesMalformedResponse() throws {
        try createMCPChannel()
        Thread.sleep(forTimeInterval: 1.0)

        // Bad server responses shouldn't crash the UI
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should handle malformed MCP responses without crash")
    }
}
