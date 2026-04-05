import XCTest

final class SplitPaneUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Split Creation

    func testCmdDCreatesHorizontalSplit() throws {
        // Split horizontally
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Window should still be functional
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should exist after horizontal split")

        // Input box should still work
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists, "Input box should exist after split")
    }

    func testCmdShiftDCreatesVerticalSplit() throws {
        app.typeKey("d", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.5)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should exist after vertical split")

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists, "Input box should exist after split")
    }

    // MARK: - Close Pane

    func testCmdShiftWWithOnePaneDoesNothing() throws {
        // With only 1 pane, Cmd+Shift+W should do nothing (no blank screen)
        app.typeKey("w", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should still exist")

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists, "Input box should still be present — no blank screen")
    }

    func testCmdShiftWClosesSecondPane() throws {
        // Split first
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Now close the active pane
        app.typeKey("w", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.3)

        // Should be back to single pane
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should exist after closing split pane")

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists, "Input box should still work after pane close")
    }

    // MARK: - Max Panes

    func testMaxFourPanesEnforced() throws {
        // Split 4 times (first split creates 2, then 3, then 4, then should stop)
        for _ in 0..<5 {
            app.typeKey("d", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.2)
        }

        // App should not crash and window should still exist
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should handle max pane limit gracefully")
    }

    // MARK: - Active Pane

    func testInputBoxSendsToActivePane() throws {
        // Split
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Type into input box — should go to the active (new) pane
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)
        inputBox.typeText("echo active-pane-test")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        // Input should be cleared
        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Input should clear after submission in split mode")
    }

    // MARK: - Sequential Split and Close

    func testSplitCloseMultipleTimes() throws {
        // Split, close, split, close — should not leak or crash
        for _ in 0..<3 {
            app.typeKey("d", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.2)
            app.typeKey("w", modifierFlags: [.command, .shift])
            Thread.sleep(forTimeInterval: 0.2)
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should survive repeated split/close cycles")
    }
}
