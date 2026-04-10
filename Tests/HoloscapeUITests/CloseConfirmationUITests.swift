import XCTest

final class CloseConfirmationUITests: HoloscapeUITestCase {

    // MARK: - Helpers

    /// Find the close confirmation dialog — NSAlert appears as a dialog or sheet.
    private func findCloseDialog(timeout: TimeInterval = 3) -> XCUIElement? {
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: timeout) { return dialog }
        let sheet = app.sheets.firstMatch
        if sheet.waitForExistence(timeout: 1) { return sheet }
        return nil
    }

    // MARK: - Confirmation Triggers

    func testCloseActiveShellShowsConfirmation() throws {
        app.typeKey("w", modifierFlags: .command)

        guard let dialog = findCloseDialog() else {
            XCTFail("Close confirmation should appear for active shell channel")
            return
        }

        let closeButton = dialog.buttons["Close"]
        let cancelButton = dialog.buttons["Cancel"]
        XCTAssertTrue(closeButton.exists, "Dialog should have Close button")
        XCTAssertTrue(cancelButton.exists, "Dialog should have Cancel button")

        // Cancel to keep channel
        cancelButton.click()

        let shellEntry = firstSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 3), "Shell sidebar entry should remain after cancel")
    }

    func testCloseActiveAgentShowsConfirmation() throws {
        try skipUnlessClaudeCLIInstalled()
        createChannel(type: "Agent (OAuth)")

        let agentEntry = sidebarEntry("Agent")
        XCTAssertTrue(agentEntry.waitForExistence(timeout: 3))
        agentEntry.click()

        app.typeKey("w", modifierFlags: .command)

        guard let dialog = findCloseDialog() else {
            XCTFail("Close confirmation should appear for active agent channel")
            return
        }

        let cancelButton = dialog.buttons["Cancel"]
        XCTAssertTrue(cancelButton.exists, "Dialog should have Cancel button")
        cancelButton.click()

        XCTAssertTrue(agentEntry.waitForExistence(timeout: 3), "Agent sidebar entry should remain after cancel")
    }

    // MARK: - Dialog Behavior

    func testConfirmationDialogHasButtons() throws {
        app.typeKey("w", modifierFlags: .command)

        guard let dialog = findCloseDialog() else {
            XCTFail("Close confirmation dialog should appear")
            return
        }

        let closeButton = dialog.buttons["Close"]
        let cancelButton = dialog.buttons["Cancel"]
        XCTAssertTrue(closeButton.exists, "Dialog should have Close button")
        XCTAssertTrue(cancelButton.exists, "Dialog should have Cancel button")

        cancelButton.click()
    }

    func testConfirmationCancelKeepsChannelOpen() throws {
        let shellEntry = firstSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 3))

        app.typeKey("w", modifierFlags: .command)

        guard let dialog = findCloseDialog() else {
            XCTFail("Close confirmation dialog should appear")
            return
        }

        let cancelButton = dialog.buttons["Cancel"]
        XCTAssertTrue(cancelButton.exists, "Dialog should have Cancel button")
        cancelButton.click()

        XCTAssertTrue(shellEntry.waitForExistence(timeout: 3), "Channel sidebar entry should remain open after Cancel")
    }

    func testConfirmationCloseRemovesChannel() throws {
        let countBefore = sidebarEntryCount()
        createChannel(type: "Shell")

        let shell2 = waitForNewSidebarEntry(expectedCount: countBefore + 1)
        XCTAssertTrue(shell2.waitForExistence(timeout: 3))
        shell2.click()

        app.typeKey("w", modifierFlags: .command)

        guard let dialog = findCloseDialog() else {
            XCTFail("Close confirmation dialog should appear")
            return
        }

        let closeButton = dialog.buttons["Close"]
        XCTAssertTrue(closeButton.exists, "Dialog should have Close button")
        closeButton.click()

        // Wait for sidebar count to decrease
        let deadline = Date().addingTimeInterval(3)
        while sidebarEntryCount() >= countBefore + 1 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertEqual(sidebarEntryCount(), countBefore, "Sidebar count should decrease after closing channel")
    }

    // MARK: - Edge Cases

    func testCloseLastChannelBehavior() throws {
        app.typeKey("w", modifierFlags: .command)

        if let dialog = findCloseDialog() {
            let closeButton = dialog.buttons["Close"]
            if closeButton.exists {
                closeButton.click()
            }
        }

        // Window should remain (app handles gracefully)
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Window should remain after closing last channel")

        assertActiveChannelResponsive(message: "Channel should be responsive after closing last channel")
    }

    func testRapidCloseDoesNotDoublePrompt() throws {
        // Press Cmd+W twice quickly
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("w", modifierFlags: .command)

        // Only one dialog should appear
        let dialogs = app.dialogs
        let dialogCount = dialogs.count
        XCTAssertLessThanOrEqual(dialogCount, 1, "Rapid Cmd+W should not produce multiple dialogs")

        if let dialog = findCloseDialog(timeout: 2) {
            let cancelButton = dialog.buttons["Cancel"]
            if cancelButton.exists { cancelButton.click() }
            else { app.typeKey(.escape, modifierFlags: []) }
        }

        // Assert no crash and window remains
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 3), "Rapid Cmd+W should not crash the app")
    }
}
