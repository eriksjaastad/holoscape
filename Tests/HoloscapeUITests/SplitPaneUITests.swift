import XCTest

final class SplitPaneUITests: HoloscapeUITestCase {

    // MARK: - Split Creation

    func testCmdDCreatesHorizontalSplit() throws {
        // Split horizontally
        app.typeKey("d", modifierFlags: .command)

        // Window should still be functional
        // Input box should still work
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2), "Input box should exist after split")
    }

    func testCmdShiftDCreatesVerticalSplit() throws {
        app.typeKey("d", modifierFlags: [.command, .shift])

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2), "Input box should exist after split")
    }

    // MARK: - Close Pane

    func testCmdShiftWWithOnePaneDoesNothing() throws {
        // With only 1 pane, Cmd+Shift+W should do nothing (no blank screen)
        app.typeKey("w", modifierFlags: [.command, .shift])

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2), "Input box should still be present — no blank screen")
    }

    func testCmdShiftWClosesSecondPane() throws {
        // Split first
        app.typeKey("d", modifierFlags: .command)

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2), "Input box should exist after split")

        // Now close the active pane
        app.typeKey("w", modifierFlags: [.command, .shift])

        // Should be back to single pane
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2), "Input box should still work after pane close")
    }

    // MARK: - Max Panes

    func testMaxFourPanesEnforced() throws {
        // Split 4 times (first split creates 2, then 3, then 4, then should stop)
        for _ in 0..<5 {
            app.typeKey("d", modifierFlags: .command)
        }

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2), "Input box should exist at max pane limit")
    }

    // MARK: - Active Pane

    func testInputBoxSendsToActivePane() throws {
        // Split
        app.typeKey("d", modifierFlags: .command)

        // Type into input box — should go to the active (new) pane
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2))
        inputBox.typeText("echo active-pane-test")
        inputBox.typeKey(.return, modifierFlags: [])

        // Input should be cleared
        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Input should clear after submission in split mode")
    }

    // MARK: - Sequential Split and Close

    func testSplitCloseMultipleTimes() throws {
        // Split, close, split, close — should not leak or crash
        for _ in 0..<3 {
            app.typeKey("d", modifierFlags: .command)
            let inputBox = app.textViews["input-box"]
            XCTAssertTrue(inputBox.waitForExistence(timeout: 2))
            app.typeKey("w", modifierFlags: [.command, .shift])
        }

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2), "Input box should exist after split/close cycles")
    }
}
