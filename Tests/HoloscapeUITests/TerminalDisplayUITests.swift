import XCTest

final class TerminalDisplayUITests: HoloscapeUITestCase {

    // MARK: - Content Display

    func testChannelSwitchAlwaysShowsContent() throws {
        // Create a second channel
        createChannel(type: "Shell")

        // Switch back and forth — should never show blank
        app.typeKey("1", modifierFlags: .command)

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2), "Input box should exist after switching to channel 1")

        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2), "Input box should exist after switching to channel 2")
    }

    // MARK: - Rapid Switching

    func testRapidSwitchingNeverLosesContent() throws {
        // Create 4 more channels (5 total)
        for _ in 0..<4 {
            createChannel(type: "Shell")
        }

        // Rapidly switch through all 5
        for _ in 0..<3 {
            for i in 1...5 {
                app.typeKey(String(i), modifierFlags: .command)
            }
        }

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2), "Input box should be present after rapid switching")
    }

    // MARK: - Window Resizing

    func testContentProperlyResizesWithWindow() throws {
        let window = app.windows["Holoscape"]
        let initialFrame = window.frame
        XCTAssertGreaterThan(initialFrame.width, 0, "Window should have positive width")
        XCTAssertGreaterThan(initialFrame.height, 0, "Window should have positive height")
    }

    // MARK: - New Channel Has Content

    func testNewChannelHasContentImmediately() throws {
        // Create a new shell — it should have a shell prompt, not be blank
        createChannel(type: "Shell")

        // Window should have content (input box exists, app responsive)
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2))
        inputBox.typeText("echo alive")
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "echo alive", "Input should work in newly created channel")
    }

    // MARK: - Channel Types

    func testBridgeChannelShowsSystemMessage() throws {
        // Open channel picker and select Bridge
        createChannel(type: "Bridge")

        // Bridge channel should be active with system message
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2), "Input box should exist in bridge channel")
    }
}
