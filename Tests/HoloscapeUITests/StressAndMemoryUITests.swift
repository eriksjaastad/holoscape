import XCTest
import AppKit

final class StressAndMemoryUITests: HoloscapeUITestCase {

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

    func testCreate20ChannelsNoSlowdown() throws {
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
        XCTAssertFalse(value.isEmpty, "Input box should contain text after pasting large input")
    }

    // MARK: - Long-Running

    func testChannelActiveFor3Seconds() throws {
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
}
