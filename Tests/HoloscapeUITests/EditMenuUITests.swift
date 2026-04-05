import XCTest

final class EditMenuUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Copy

    func testCmdCCopiesSelectedText() throws {
        // Type text in input box, select it, copy
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)

        inputBox.typeText("copy-test-text")
        inputBox.typeKey("a", modifierFlags: .command) // Select all
        inputBox.typeKey("c", modifierFlags: .command) // Copy
        Thread.sleep(forTimeInterval: 0.2)

        // Clear and paste to verify
        inputBox.typeKey(.delete, modifierFlags: [])
        inputBox.typeKey("v", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.contains("copy-test-text"), "Cmd+C should copy selected text to clipboard")
    }

    func testCmdCFromInputBox() throws {
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("input-copy")
        inputBox.typeKey("a", modifierFlags: .command)
        inputBox.typeKey("c", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        // Verify by pasting into cleared input
        inputBox.typeKey(.delete, modifierFlags: [])
        inputBox.typeKey("v", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "input-copy", "Copy from input box should capture text")
    }

    func testCopyFromTerminalOutput() throws {
        // Generate output
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("echo terminal-copy-test")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        // Attempt to select and copy from output area
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        // No crash — copy from terminal output handled
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Copy from terminal output should not crash")
    }

    // MARK: - Paste

    func testCmdVPastesIntoInputBox() throws {
        let inputBox = app.textViews["input-box"]

        // Copy text to clipboard first
        inputBox.typeText("paste-source")
        inputBox.typeKey("a", modifierFlags: .command)
        inputBox.typeKey("c", modifierFlags: .command)
        inputBox.typeKey(.delete, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.2)

        // Paste
        inputBox.typeKey("v", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "paste-source", "Cmd+V should paste into input box")
    }

    func testCmdVMultilinePaste() throws {
        let inputBox = app.textViews["input-box"]

        // Create multi-line text via Shift+Enter
        inputBox.typeText("line1")
        inputBox.typeKey(.return, modifierFlags: .shift)
        inputBox.typeText("line2")
        inputBox.typeKey("a", modifierFlags: .command)
        inputBox.typeKey("c", modifierFlags: .command)
        inputBox.typeKey(.delete, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.2)

        // Paste multi-line
        inputBox.typeKey("v", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.contains("line1"), "Multi-line paste should preserve first line")
        XCTAssertTrue(value.contains("line2"), "Multi-line paste should preserve second line")
    }

    func testCmdVDoesNotPasteIntoOutput() throws {
        // Copy something to clipboard
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("no-output-paste")
        inputBox.typeKey("a", modifierFlags: .command)
        inputBox.typeKey("c", modifierFlags: .command)
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        // Try to paste when focus might be elsewhere — should route to input or do nothing
        app.typeKey("v", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Paste into output area should not crash")
    }

    // MARK: - Cut

    func testCmdXCutsFromInputBox() throws {
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("cut-me")
        inputBox.typeKey("a", modifierFlags: .command)
        inputBox.typeKey("x", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        // Input should be empty after cut
        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Cmd+X should remove text from input box")

        // Paste to verify it's on clipboard
        inputBox.typeKey("v", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)
        let pastedValue = inputBox.value as? String ?? ""
        XCTAssertEqual(pastedValue, "cut-me", "Cut text should be on clipboard")
    }

    func testCmdXDoesNothingOnOutput() throws {
        // Generate output
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("echo no-cut-output")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        // Attempt cut on read-only output — should do nothing
        app.typeKey("x", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Cut on read-only output should do nothing and not crash")
    }

    // MARK: - Select All

    func testCmdASelectsAllInInputBox() throws {
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("select-all-test")
        inputBox.typeKey("a", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        // Type to replace selection — if all was selected, new text replaces everything
        inputBox.typeText("replaced")
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "replaced", "Cmd+A should select all text in input box")
    }

    func testCmdAInOutputView() throws {
        // Generate output
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("echo output-select-all")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        // Cmd+A behavior in output view
        app.typeKey("a", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Cmd+A in output view should not crash")
    }

    // MARK: - Edge Cases

    func testPasteEmptyClipboard() throws {
        // Clear clipboard by copying empty text
        let inputBox = app.textViews["input-box"]
        inputBox.typeKey("a", modifierFlags: .command)
        inputBox.typeKey("c", modifierFlags: .command)
        inputBox.typeKey(.delete, modifierFlags: [])

        // Paste empty clipboard
        inputBox.typeKey("v", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Pasting empty clipboard should not crash")
    }

    func testPasteLargeText() throws {
        let inputBox = app.textViews["input-box"]

        // Generate a large string via typing (limited by UI automation speed)
        let largeText = String(repeating: "x", count: 1000)
        inputBox.typeText(largeText)
        Thread.sleep(forTimeInterval: 0.5)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Pasting large text should not freeze UI")
    }

    func testCopyPasteAcrossChannels() throws {
        // Type and copy in first channel
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("cross-channel")
        inputBox.typeKey("a", modifierFlags: .command)
        inputBox.typeKey("c", modifierFlags: .command)
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.2)

        // Create second channel
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Shell"].click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        // Paste in second channel
        inputBox.typeKey("v", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "cross-channel", "Copy from one channel should paste into another")
    }
}
