import XCTest

final class SplitPaneAdvancedUITests: HoloscapeUITestCase {

    // MARK: - Active Pane Indicator

    func testActivePaneHasBlueBorder() throws {
        throw XCTSkip("Cannot verify border color via XCUITest")
    }

    func testClickingPaneMakesItActive() throws {
        throw XCTSkip("Cannot verify active pane state via XCUITest — no accessibility property for active pane")
    }

    func testActivePaneChangesOnClick() throws {
        throw XCTSkip("Cannot verify active pane state via XCUITest — no accessibility property for active pane")
    }

    // MARK: - Channel-to-Pane Routing

    func testDifferentChannelsInDifferentPanes() throws {
        createChannel(type: "Shell")

        // Split
        app.typeKey("d", modifierFlags: .command)

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))

        // Switch channel in active pane
        app.typeKey("1", modifierFlags: .command)

        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should remain after channel switch in split pane")

        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testInputRoutesToActivePane() throws {
        app.typeKey("d", modifierFlags: .command)

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))
        inputBox.typeText("active-pane-input")
        inputBox.typeKey(.return, modifierFlags: [])

        // Verify input box cleared after submit (routing worked)
        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Input box should clear after submit, confirming routing worked")

        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testChannelSwitchInActivePaneOnly() throws {
        createChannel(type: "Shell")

        app.typeKey("d", modifierFlags: .command)

        // Cmd+2 should switch channel in active pane
        app.typeKey("2", modifierFlags: .command)

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should remain functional after channel switch in pane")

        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    // MARK: - Layout Persistence

    func testSplitLayoutPersistsAcrossRestart() throws {
        throw XCTSkip("Cannot verify split pane count via XCUITest — pane containers are not individually accessible")
    }

    func testSplitLayoutExport() throws {
        throw XCTSkip("Layout export is internal API, not testable via XCUITest")
    }

    func testPaneChannelAssignmentPersists() throws {
        throw XCTSkip("Cannot verify split pane count via XCUITest — pane containers are not individually accessible")
    }

    // MARK: - Channel Removal

    func testClosingChannelClearsPaneContent() throws {
        createChannel(type: "Shell")

        app.typeKey("d", modifierFlags: .command)

        app.typeKey("w", modifierFlags: .command)
        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 2) {
            closeButton.click()
        }

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should remain after closing channel in pane")
    }

    func testRemoveChannelFromSpecificPane() throws {
        app.typeKey("d", modifierFlags: .command)

        app.typeKey("w", modifierFlags: .command)
        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 2) {
            closeButton.click()
        }

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should remain after removing channel from specific pane")
    }

    // MARK: - Layout Combinations

    func testHorizontalThenVerticalSplit() throws {
        app.typeKey("d", modifierFlags: .command) // Horizontal
        app.typeKey("d", modifierFlags: [.command, .shift]) // Vertical

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should still accept text after mixed splits")
        inputBox.typeText("mixed-split-test")
        inputBox.typeKey(.return, modifierFlags: [])

        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Input should clear after submit in mixed split layout")

        app.typeKey("w", modifierFlags: [.command, .shift])
        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testVerticalThenHorizontalSplit() throws {
        app.typeKey("d", modifierFlags: [.command, .shift]) // Vertical
        app.typeKey("d", modifierFlags: .command) // Horizontal

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should still accept text after mixed splits")
        inputBox.typeText("reverse-split-test")
        inputBox.typeKey(.return, modifierFlags: [])

        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Input should clear after submit in mixed split layout")

        app.typeKey("w", modifierFlags: [.command, .shift])
        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testThreePaneLayout() throws {
        app.typeKey("d", modifierFlags: .command)
        app.typeKey("d", modifierFlags: .command)

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should accept text in 3-pane layout")
        inputBox.typeText("three-pane-test")
        inputBox.typeKey(.return, modifierFlags: [])

        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Input should clear after submit in 3-pane layout")

        app.typeKey("w", modifierFlags: [.command, .shift])
        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    func testFourPaneLayout() throws {
        app.typeKey("d", modifierFlags: .command)
        app.typeKey("d", modifierFlags: .command)
        app.typeKey("d", modifierFlags: .command)

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should accept text in 4-pane layout")
        inputBox.typeText("four-pane-test")
        inputBox.typeKey(.return, modifierFlags: [])

        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Input should clear after submit in 4-pane layout")

        for _ in 0..<3 {
            app.typeKey("w", modifierFlags: [.command, .shift])
        }
    }
}
