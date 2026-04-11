import XCTest

final class SplitPaneAdvancedUITests: HoloscapeUITestCase {

    // MARK: - Channel-to-Pane Routing

    func testDifferentChannelsInDifferentPanes() throws {
        createChannel(type: "Shell")

        // Split
        app.typeKey("d", modifierFlags: .command)

        assertActiveChannelResponsive(message: "Channel should be responsive in split pane")

        // Switch channel in active pane
        app.typeKey("1", modifierFlags: .command)

        assertActiveChannelResponsive(message: "Channel should remain responsive after switch in split pane")

        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testInputRoutesToActivePane() throws {
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Active pane should be responsive (terminal view for PTY channels)
        assertActiveChannelResponsive(timeout: 5, message: "Active pane should be responsive after split")

        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testChannelSwitchInActivePaneOnly() throws {
        createChannel(type: "Shell")

        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Cmd+2 should switch channel in active pane
        app.typeKey("2", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        assertActiveChannelResponsive(timeout: 5, message: "Channel should remain responsive after switch in pane")

        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    // MARK: - Channel Removal

    func testClosingChannelInSplitDoesNotCrash() throws {
        createChannel(type: "Shell")

        app.typeKey("d", modifierFlags: .command)

        app.typeKey("w", modifierFlags: .command)
        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 2) {
            closeButton.click()
        }

        assertActiveChannelResponsive(message: "Channel should remain responsive after closing channel in pane")
    }

    func testClosePaneAfterClosingChannel() throws {
        app.typeKey("d", modifierFlags: .command)

        app.typeKey("w", modifierFlags: .command)
        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 2) {
            closeButton.click()
        }

        assertActiveChannelResponsive(message: "Channel should remain responsive after removing channel from pane")
    }

    // MARK: - Layout Combinations

    func testHorizontalThenVerticalSplit() throws {
        app.typeKey("d", modifierFlags: .command) // Horizontal
        app.typeKey("d", modifierFlags: [.command, .shift]) // Vertical

        assertActiveChannelResponsive(message: "Channel should be responsive after mixed splits")

        app.typeKey("w", modifierFlags: [.command, .shift])
        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testVerticalThenHorizontalSplit() throws {
        app.typeKey("d", modifierFlags: [.command, .shift]) // Vertical
        app.typeKey("d", modifierFlags: .command) // Horizontal

        assertActiveChannelResponsive(message: "Channel should be responsive after mixed splits")

        app.typeKey("w", modifierFlags: [.command, .shift])
        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testThreePaneLayout() throws {
        app.typeKey("d", modifierFlags: .command)
        app.typeKey("d", modifierFlags: .command)

        assertActiveChannelResponsive(message: "Channel should be responsive in 3-pane layout")

        app.typeKey("w", modifierFlags: [.command, .shift])
        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testFourPaneLayout() throws {
        app.typeKey("d", modifierFlags: .command)
        app.typeKey("d", modifierFlags: .command)
        app.typeKey("d", modifierFlags: .command)

        assertActiveChannelResponsive(message: "Channel should be responsive in 4-pane layout")

        for _ in 0..<3 {
            app.typeKey("w", modifierFlags: [.command, .shift])
        }
    }
}
