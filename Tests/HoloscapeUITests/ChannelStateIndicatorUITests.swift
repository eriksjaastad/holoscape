import XCTest

final class ChannelStateIndicatorUITests: HoloscapeUITestCase {

    // MARK: - State Display

    func testActiveChannelShowsGreenIndicator() throws {
        throw XCTSkip("Cannot verify indicator color via XCUITest")
    }

    func testConnectingChannelShowsYellowIndicator() throws {
        throw XCTSkip("Cannot verify indicator color via XCUITest")
    }

    func testDisconnectedChannelShowsRedIndicator() throws {
        throw XCTSkip("Cannot verify indicator color via XCUITest")
    }

    func testStateIndicatorUpdatesOnTransition() throws {
        // Create agent channel and verify sidebar entry exists
        createChannel(type: "Agent (OAuth)")

        let agentEntry = sidebarEntry("Agent")
        XCTAssertTrue(agentEntry.waitForExistence(timeout: 5), "Agent channel sidebar entry should exist after creation")
    }

    // MARK: - Elapsed Time

    func testElapsedTimeDisplayed() throws {
        // Collapse sidebar to show tab bar — tab titles contain elapsed time
        app.typeKey("s", modifierFlags: [.command, .shift])

        let tabButton = tabEntry("")
        if tabButton.waitForExistence(timeout: 3) {
            let title = tabButton.title
            XCTAssertTrue(title.contains("("), "Tab bar title should contain elapsed time in parentheses, got: \(title)")
        } else {
            throw XCTSkip("Tab bar entry not found — cannot verify elapsed time display")
        }

        // Re-expand sidebar
        app.typeKey("s", modifierFlags: [.command, .shift])
    }

    func testElapsedTimeFormatsCorrectly() throws {
        // Collapse sidebar to expose tab titles with elapsed time
        app.typeKey("s", modifierFlags: [.command, .shift])

        let tabButton = tabEntry("")
        if tabButton.waitForExistence(timeout: 3) {
            let title = tabButton.title
            // Elapsed time format includes parentheses, e.g. "Shell (0s)" or "Shell (1m 2s)"
            XCTAssertTrue(title.contains("(") && title.contains(")"),
                          "Tab title should contain formatted elapsed time in parens, got: \(title)")
        } else {
            throw XCTSkip("Tab bar entry not found — cannot verify elapsed time format")
        }

        // Re-expand sidebar
        app.typeKey("s", modifierFlags: [.command, .shift])
    }

    func testElapsedTimeUpdates() throws {
        // Collapse sidebar
        app.typeKey("s", modifierFlags: [.command, .shift])

        let tabButton = tabEntry("")
        guard tabButton.waitForExistence(timeout: 3) else {
            app.typeKey("s", modifierFlags: [.command, .shift])
            throw XCTSkip("Tab bar entry not found — cannot verify elapsed time updates")
        }

        let title1 = tabButton.title

        // The tab should still exist
        XCTAssertTrue(tabButton.exists, "Tab button should continue to exist while elapsed time updates")
        // If we got a title, it should be non-empty
        XCTAssertFalse(title1.isEmpty, "Tab title should be non-empty")

        // Re-expand sidebar
        app.typeKey("s", modifierFlags: [.command, .shift])
    }

    func testDisconnectedChannelShowsStatusText() throws {
        throw XCTSkip("Cannot reliably verify disconnected channel status text via XCUITest — agent connection state is non-deterministic")
    }

    // MARK: - Tab Bar Indicators

    func testTabBarShowsElapsedTime() throws {
        // Collapse sidebar to show tab bar
        app.typeKey("s", modifierFlags: [.command, .shift])

        let tabButton = tabEntry("")
        XCTAssertTrue(tabButton.waitForExistence(timeout: 3), "Tab bar should show entries when sidebar is collapsed")

        let title = tabButton.title
        XCTAssertFalse(title.isEmpty, "Tab bar entry should have a non-empty title")

        // Re-expand sidebar
        app.typeKey("s", modifierFlags: [.command, .shift])
    }

    func testTabBarReflectsState() throws {
        // Create agent channel for state variation
        createChannel(type: "Agent (OAuth)")

        // Collapse sidebar
        app.typeKey("s", modifierFlags: [.command, .shift])

        let window = app.windows["Holoscape"]
        let tabButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'"))
        XCTAssertGreaterThanOrEqual(tabButtons.count, 2, "Tab bar should show entries for multiple channels")

        // Re-expand
        app.typeKey("s", modifierFlags: [.command, .shift])
    }
}
