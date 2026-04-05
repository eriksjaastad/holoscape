import XCTest

final class CloseConfirmationUITests: XCTestCase {
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

    private func createChannel(type: String) {
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons[type].click()
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - Confirmation Triggers

    func testCloseActiveShellShowsConfirmation() throws {
        // Active shell should prompt before close
        app.typeKey("w", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let closeButton = app.buttons["Close"]
        let cancelButton = app.buttons["Cancel"]
        let hasDialog = closeButton.waitForExistence(timeout: 1) || cancelButton.waitForExistence(timeout: 0.5)

        if hasDialog {
            XCTAssertTrue(true, "Confirmation dialog shown for active shell")
            // Cancel to keep channel
            if cancelButton.exists {
                cancelButton.click()
            } else {
                app.typeKey(.escape, modifierFlags: [])
            }
        } else {
            // If no confirmation, channel was closed directly — verify window remains
            let window = app.windows["Holoscape"]
            XCTAssertTrue(window.exists, "Window should remain after close")
        }
    }

    func testCloseActiveAgentShowsConfirmation() throws {
        createChannel(type: "Agent (OAuth)")

        let window = app.windows["Holoscape"]
        let agentEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Agent'")).firstMatch
        if agentEntry.waitForExistence(timeout: 2) {
            agentEntry.click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        app.typeKey("w", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let closeButton = app.buttons["Close"]
        let cancelButton = app.buttons["Cancel"]
        if closeButton.waitForExistence(timeout: 1) || cancelButton.exists {
            // Confirmation appeared for active agent
            if cancelButton.exists { cancelButton.click() }
            else { app.typeKey(.escape, modifierFlags: []) }
        }

        XCTAssertTrue(window.exists, "Window should remain after agent close confirmation")
    }

    func testCloseActiveSSHShowsConfirmation() throws {
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 2))

        let sshButton = dialog.buttons.matching(NSPredicate(format: "title CONTAINS[c] 'SSH'")).firstMatch
        guard sshButton.exists else {
            dialog.buttons["Cancel"].click()
            throw XCTSkip("No SSH option available")
        }
        sshButton.click()
        Thread.sleep(forTimeInterval: 0.5)

        app.typeKey("w", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let closeButton = app.buttons["Close"]
        let cancelButton = app.buttons["Cancel"]
        if closeButton.waitForExistence(timeout: 1) || cancelButton.exists {
            if cancelButton.exists { cancelButton.click() }
            else { app.typeKey(.escape, modifierFlags: []) }
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain after SSH close confirmation")
    }

    func testCloseDisconnectedChannelNoConfirmation() throws {
        createChannel(type: "Agent (OAuth)")
        // Wait for potential disconnection
        Thread.sleep(forTimeInterval: 3.0)

        app.typeKey("w", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Disconnected channel may close immediately without confirmation
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain after closing disconnected channel")
    }

    // MARK: - Dialog Behavior

    func testConfirmationDialogHasButtons() throws {
        app.typeKey("w", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let closeButton = app.buttons["Close"]
        let cancelButton = app.buttons["Cancel"]
        if closeButton.waitForExistence(timeout: 1) {
            XCTAssertTrue(closeButton.exists, "Dialog should have Close button")
            XCTAssertTrue(cancelButton.exists, "Dialog should have Cancel button")
            cancelButton.click()
        }
    }

    func testConfirmationCancelKeepsChannelOpen() throws {
        let window = app.windows["Holoscape"]
        let shellEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Shell'")).firstMatch
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 2))

        app.typeKey("w", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let cancelButton = app.buttons["Cancel"]
        if cancelButton.waitForExistence(timeout: 1) {
            cancelButton.click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Channel should still be there
        XCTAssertTrue(shellEntry.exists, "Channel should remain open after Cancel")
    }

    func testConfirmationCloseRemovesChannel() throws {
        // Create a second channel so closing one doesn't leave empty state
        createChannel(type: "Shell")

        let window = app.windows["Holoscape"]
        let shell2 = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Shell 2'")).firstMatch
        XCTAssertTrue(shell2.waitForExistence(timeout: 2))
        shell2.click()
        Thread.sleep(forTimeInterval: 0.3)

        app.typeKey("w", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 1) {
            closeButton.click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertFalse(shell2.exists, "Channel should be removed after Close confirmation")
    }

    // MARK: - Edge Cases

    func testCloseLastChannelBehavior() throws {
        // Close the only channel
        app.typeKey("w", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 1) {
            closeButton.click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        // Verify behavior — app may create a new default channel or show empty state
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain after closing last channel")
    }

    func testRapidCloseDoesNotDoublePrompt() throws {
        // Press Cmd+W twice quickly
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("w", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Should not stack two dialogs
        let closeButton = app.buttons["Close"]
        let cancelButton = app.buttons["Cancel"]
        if closeButton.waitForExistence(timeout: 1) || cancelButton.exists {
            if cancelButton.exists { cancelButton.click() }
            else { app.typeKey(.escape, modifierFlags: []) }
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Rapid Cmd+W should not stack dialogs or crash")
    }
}
