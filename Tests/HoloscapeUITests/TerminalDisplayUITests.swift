import XCTest

final class TerminalDisplayUITests: HoloscapeUITestCase {

    // MARK: - Content Display

    func testChannelSwitchAlwaysShowsContent() throws {
        // Create a second channel
        createChannel(type: "Shell")

        // Switch back and forth — should never show blank
        app.typeKey("1", modifierFlags: .command)

        assertActiveChannelResponsive(message: "Channel should be responsive after switching to channel 1")

        app.typeKey("2", modifierFlags: .command)
        assertActiveChannelResponsive(message: "Channel should be responsive after switching to channel 2")
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

        assertActiveChannelResponsive(message: "Channel should be responsive after rapid switching")
    }

    // MARK: - Window Resizing

    func testWindowHasPositiveDimensions() throws {
        let window = app.windows["Holoscape"]
        let initialFrame = window.frame
        XCTAssertGreaterThan(initialFrame.width, 0, "Window should have positive width")
        XCTAssertGreaterThan(initialFrame.height, 0, "Window should have positive height")
    }

    // MARK: - New Channel Has Content

    func testNewChannelHasContentImmediately() throws {
        // Create a new shell — it should have a shell prompt, not be blank
        createChannel(type: "Shell")

        // Window should have content (terminal view exists, app responsive)
        assertActiveChannelResponsive(message: "Newly created shell channel should be responsive")
    }

    // MARK: - Channel Types

    func testBridgeChannelViewLoads() throws {
        createChannel(type: "Bridge")

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2), "Input box should exist in bridge channel")

        // Verify output area loaded
        let window = app.windows["Holoscape"]
        XCTAssertGreaterThanOrEqual(window.scrollViews.count, 1, "Bridge channel should have an output scroll view")
    }
}
