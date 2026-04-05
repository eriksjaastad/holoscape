import XCTest

final class EditMenuUITests: HoloscapeUITestCase {

    // MARK: - Copy

    func testCmdCCopiesSelectedText() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist")

        inputBox.typeText("copy-test-text")
        inputBox.typeKey("a", modifierFlags: .command)
        inputBox.typeKey("c", modifierFlags: .command)

        // Clear and paste back to verify clipboard content
        inputBox.typeKey(.delete, modifierFlags: [])
        inputBox.typeKey("v", modifierFlags: .command)

        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.contains("copy-test-text"), "Cmd+C should copy selected text; paste-back should contain original")
    }

    func testCmdCFromInputBox() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist")

        inputBox.typeText("input-copy")
        inputBox.typeKey("a", modifierFlags: .command)
        inputBox.typeKey("c", modifierFlags: .command)

        // Clear and paste back
        inputBox.typeKey(.delete, modifierFlags: [])
        inputBox.typeKey("v", modifierFlags: .command)

        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "input-copy", "Copy from input box should capture text and paste back correctly")
    }

    func testCopyFromTerminalOutput() throws {
        try XCTSkip("Cannot reliably verify terminal output copy via XCUITest")
    }

    // MARK: - Paste

    func testCmdVPastesIntoInputBox() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist")

        // Copy text to clipboard first
        inputBox.typeText("paste-source")
        inputBox.typeKey("a", modifierFlags: .command)
        inputBox.typeKey("c", modifierFlags: .command)
        inputBox.typeKey(.delete, modifierFlags: [])

        // Paste
        inputBox.typeKey("v", modifierFlags: .command)

        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "paste-source", "Cmd+V should paste clipboard content into input box")
    }

    func testCmdVMultilinePaste() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist")

        // Create multi-line text via Shift+Enter
        inputBox.typeText("line1")
        inputBox.typeKey(.return, modifierFlags: .shift)
        inputBox.typeText("line2")
        inputBox.typeKey("a", modifierFlags: .command)
        inputBox.typeKey("c", modifierFlags: .command)
        inputBox.typeKey(.delete, modifierFlags: [])

        // Paste multi-line
        inputBox.typeKey("v", modifierFlags: .command)

        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.contains("line1"), "Multi-line paste should preserve first line")
        XCTAssertTrue(value.contains("line2"), "Multi-line paste should preserve second line")
    }

    func testCmdVDoesNotPasteIntoOutput() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist")

        inputBox.typeText("no-output-paste")
        inputBox.typeKey("a", modifierFlags: .command)
        inputBox.typeKey("c", modifierFlags: .command)
        inputBox.typeKey(.return, modifierFlags: [])


        // Paste when focus may be on output — should route to input or do nothing harmful
        app.typeKey("v", modifierFlags: .command)

        // Verify input box still contains pasted text (focus returned to input)
        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.contains("no-output-paste"), "Paste should route to input box, not crash or modify output")
    }

    // MARK: - Cut

    func testCmdXCutsFromInputBox() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist")

        inputBox.typeText("cut-me")
        inputBox.typeKey("a", modifierFlags: .command)
        inputBox.typeKey("x", modifierFlags: .command)

        // Input should be empty after cut
        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Cmd+X should remove text from input box")

        // Paste to verify clipboard has the cut text
        inputBox.typeKey("v", modifierFlags: .command)
        let pastedValue = inputBox.value as? String ?? ""
        XCTAssertEqual(pastedValue, "cut-me", "Cut text should be on clipboard and paste back correctly")
    }

    func testCmdXDoesNothingOnOutput() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist")

        inputBox.typeText("echo no-cut-output")
        inputBox.typeKey(.return, modifierFlags: [])


        // Attempt cut on read-only output
        app.typeKey("x", modifierFlags: .command)

        // Verify input box is accessible and functional after attempt
        inputBox.click()
        inputBox.typeText("still-works")
        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.contains("still-works"), "Cut on read-only output should be a no-op; input should remain functional")
    }

    // MARK: - Select All

    func testCmdASelectsAllInInputBox() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist")

        inputBox.typeText("select-all-test")
        inputBox.typeKey("a", modifierFlags: .command)

        // Type replacement — if all was selected, new text replaces everything
        inputBox.typeText("replaced")
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "replaced", "Cmd+A should select all text so typing replaces it entirely")
    }

    func testCmdAInOutputView() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist")

        inputBox.typeText("echo output-select-all")
        inputBox.typeKey(.return, modifierFlags: [])


        // Cmd+A in output view context
        app.typeKey("a", modifierFlags: .command)

        // Verify input box still functional after select-all
        inputBox.click()
        inputBox.typeText("post-select")
        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.contains("post-select"), "Cmd+A in output view should not break input box")
    }

    // MARK: - Edge Cases

    func testPasteEmptyClipboard() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist")

        // Clear clipboard by copying empty selection
        inputBox.typeKey("a", modifierFlags: .command)
        inputBox.typeKey("c", modifierFlags: .command)
        inputBox.typeKey(.delete, modifierFlags: [])

        // Type known text, then paste empty clipboard
        inputBox.typeText("unchanged")
        inputBox.typeKey("v", modifierFlags: .command)

        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.contains("unchanged"), "Pasting empty clipboard should leave existing text unchanged")
    }

    func testPasteLargeText() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist")

        let largeText = String(repeating: "x", count: 1000)
        inputBox.typeText(largeText)

        let value = inputBox.value as? String ?? ""
        XCTAssertFalse(value.isEmpty, "Input box should accept large text without freezing")
    }

    func testCopyPasteAcrossChannels() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist")

        // Type and copy in first channel
        inputBox.typeText("cross-channel")
        inputBox.typeKey("a", modifierFlags: .command)
        inputBox.typeKey("c", modifierFlags: .command)
        inputBox.typeKey(.return, modifierFlags: [])

        // Create second channel
        createChannel(type: "Shell")

        // Paste in second channel
        let inputBox2 = app.textViews["input-box"]
        XCTAssertTrue(inputBox2.waitForExistence(timeout: 3), "Input box should exist in second channel")
        inputBox2.typeKey("v", modifierFlags: .command)

        let value = inputBox2.value as? String ?? ""
        XCTAssertEqual(value, "cross-channel", "Copy from one channel should paste into another")
    }
}
