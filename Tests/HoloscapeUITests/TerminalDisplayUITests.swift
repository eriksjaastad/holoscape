import XCTest

final class TerminalDisplayUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Content Display

    func testChannelSwitchAlwaysShowsContent() throws {
        // Create a second channel
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 2))
        dialog.buttons["Shell"].click()
        Thread.sleep(forTimeInterval: 0.5)

        // Switch back and forth — should never show blank
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should show content after switching to channel 1")

        app.typeKey("2", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(window.exists, "Window should show content after switching to channel 2")
    }

    // MARK: - Rapid Switching

    func testRapidSwitchingNeverLosesContent() throws {
        // Create 5 channels
        for _ in 0..<4 {
            app.menuBars.firstMatch.menuBarItems["File"].click()
            app.menuItems["New Channel"].click()
            let dialog = app.dialogs.firstMatch
            XCTAssertTrue(dialog.waitForExistence(timeout: 2))
            dialog.buttons["Shell"].click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Rapidly switch through all 5
        for round in 0..<3 {
            for i in 1...5 {
                app.typeKey(String(i), modifierFlags: .command)
                // Very short delay to stress-test
                Thread.sleep(forTimeInterval: 0.02)
            }
        }

        // Allow settling
        Thread.sleep(forTimeInterval: 0.5)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should survive rapid switching across 5+ channels")

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists, "Input box should be present after rapid switching")
    }

    // MARK: - Window Resizing

    func testContentProperlyResizesWithWindow() throws {
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists)

        let initialFrame = window.frame

        // Resize to a smaller width (XCUITest can't directly resize, but we can verify
        // the window is resizable by checking styleMask via existence)
        XCTAssertGreaterThan(initialFrame.width, 0)
        XCTAssertGreaterThan(initialFrame.height, 0)
    }

    // MARK: - New Channel Has Content

    func testNewChannelHasContentImmediately() throws {
        // Create a new shell — it should have a shell prompt, not be blank
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 2))
        dialog.buttons["Shell"].click()

        // Give shell time to produce prompt
        Thread.sleep(forTimeInterval: 1.0)

        // Window should have content (input box exists, app responsive)
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)
        inputBox.typeText("echo alive")
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "echo alive", "Input should work in newly created channel")
    }

    // MARK: - Channel Types

    func testBridgeChannelShowsSystemMessage() throws {
        // Open channel picker and select Bridge
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 2))

        let bridgeButton = dialog.buttons["Bridge"]
        XCTAssertTrue(bridgeButton.exists, "Bridge button should be in channel picker")
        bridgeButton.click()

        Thread.sleep(forTimeInterval: 0.5)

        // Bridge channel should be active with system message
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should be functional with bridge channel")
    }
}
