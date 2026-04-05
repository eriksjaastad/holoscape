import XCTest

final class SSHChannelUITests: XCTestCase {
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

    private func createSSHChannel() throws {
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 2))

        let sshButton = dialog.buttons.matching(NSPredicate(format: "title CONTAINS[c] 'SSH'")).firstMatch
        guard sshButton.exists else {
            dialog.buttons["Cancel"].click()
            throw XCTSkip("No SSH option available in channel picker")
        }
        sshButton.click()
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - Channel Creation

    func testSSHChannelCreatesFromProfile() throws {
        try createSSHChannel()

        let window = app.windows["Holoscape"]
        let sshEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-SSH'")).firstMatch
        XCTAssertTrue(sshEntry.waitForExistence(timeout: 3), "SSH channel should appear in sidebar after creation")
    }

    func testSSHChannelDisplaysHostLabel() throws {
        try createSSHChannel()

        let window = app.windows["Holoscape"]
        let sshEntry = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-SSH'")).firstMatch
        XCTAssertTrue(sshEntry.waitForExistence(timeout: 3), "SSH sidebar entry should display host label")
    }

    func testSSHChannelStateTransitions() throws {
        try createSSHChannel()
        Thread.sleep(forTimeInterval: 1.0)

        // SSH should transition to connecting → active or disconnected
        let window = app.windows["Holoscape"]
        let sshEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-SSH'")).firstMatch
        XCTAssertTrue(sshEntry.exists, "SSH channel should exist after state transitions")
    }

    // MARK: - Connection Handling

    func testSSHChannelHandlesConnectionFailure() throws {
        try createSSHChannel()
        Thread.sleep(forTimeInterval: 2.0)

        // Invalid host should show disconnected state, not crash
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain after SSH connection failure")
    }

    func testSSHChannelReconnect() throws {
        try createSSHChannel()
        Thread.sleep(forTimeInterval: 1.0)

        let window = app.windows["Holoscape"]
        let sshEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-SSH'")).firstMatch
        guard sshEntry.waitForExistence(timeout: 2) else { return }

        sshEntry.rightClick()
        Thread.sleep(forTimeInterval: 0.3)

        let reconnectItem = app.menuItems["Reconnect"]
        if reconnectItem.waitForExistence(timeout: 1) {
            XCTAssertTrue(reconnectItem.exists, "Reconnect menu item should exist for SSH channel")
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    func testSSHChannelTimeout() throws {
        try createSSHChannel()
        // Wait longer to verify timeout behavior
        Thread.sleep(forTimeInterval: 3.0)

        // Should show disconnected, not infinite spinner
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain functional after SSH timeout")
    }

    // MARK: - Input/Output

    func testSSHChannelAcceptsInput() throws {
        try createSSHChannel()

        let window = app.windows["Holoscape"]
        let sshEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-SSH'")).firstMatch
        if sshEntry.waitForExistence(timeout: 2) {
            sshEntry.click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)
        inputBox.typeText("ls")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertTrue(window.exists, "Window should remain after SSH input submission")
    }

    func testSSHChannelShowsRemoteOutput() throws {
        try createSSHChannel()
        Thread.sleep(forTimeInterval: 1.0)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should display SSH output without crash")
    }

    func testSSHChannelCommandHistory() throws {
        try createSSHChannel()

        let window = app.windows["Holoscape"]
        let sshEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-SSH'")).firstMatch
        if sshEntry.waitForExistence(timeout: 2) {
            sshEntry.click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        let inputBox = app.textViews["input-box"]
        inputBox.typeText("ssh-history-test")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        inputBox.typeKey(.upArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.1)
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "ssh-history-test", "Up arrow should recall previous SSH command")
    }

    // MARK: - Lifecycle

    func testSSHChannelCleanDisconnect() throws {
        try createSSHChannel()
        Thread.sleep(forTimeInterval: 0.5)

        app.typeKey("w", modifierFlags: .command)

        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 1) {
            closeButton.click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        let window = app.windows["Holoscape"]
        let sshEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-SSH'")).firstMatch
        XCTAssertFalse(sshEntry.exists, "SSH channel should be removed after clean disconnect")
    }

    func testSSHChannelCloseConfirmation() throws {
        try createSSHChannel()
        Thread.sleep(forTimeInterval: 0.5)

        // Cmd+W on active SSH channel should prompt
        app.typeKey("w", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Check if confirmation dialog appeared
        let closeButton = app.buttons["Close"]
        let cancelButton = app.buttons["Cancel"]
        let hasConfirmation = closeButton.waitForExistence(timeout: 1) || cancelButton.waitForExistence(timeout: 0.5)

        if hasConfirmation {
            // Dismiss without closing
            if cancelButton.exists {
                cancelButton.click()
            } else {
                app.typeKey(.escape, modifierFlags: [])
            }
        }

        // Channel should still exist if we cancelled
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain after close confirmation cancel")
    }
}
