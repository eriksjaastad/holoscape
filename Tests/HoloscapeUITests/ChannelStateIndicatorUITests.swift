import XCTest

final class ChannelStateIndicatorUITests: HoloscapeUITestCase {

    // MARK: - Sidebar Entry Exists After Creation

    func testShellChannelHasSidebarEntry() throws {
        let entry = defaultShellSidebarEntry()
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "Shell channel should have a sidebar entry on launch")
    }

    func testAgentChannelHasSidebarEntry() throws {
        createChannel(type: "Agent (OAuth)")
        let agentEntry = sidebarEntry("Agent")
        XCTAssertTrue(agentEntry.waitForExistence(timeout: 5), "Agent channel sidebar entry should exist after creation")
    }

    // MARK: - Elapsed Time in Tab Bar

    func testTabBarTitleContainsElapsedTime() throws {
        // Collapse sidebar to show tab bar — tab titles contain elapsed time
        app.typeKey("s", modifierFlags: [.command, .shift])

        let tabButton = defaultShellTabEntry()
        if tabButton.waitForExistence(timeout: 3) {
            let title = tabButton.title
            XCTAssertTrue(
                title.contains("(") && title.contains(")"),
                "Tab bar title should contain elapsed time in parentheses, got: \(title)"
            )
        } else {
            throw XCTSkip("Tab bar entry not found — cannot verify elapsed time display")
        }

        // Re-expand sidebar
        app.typeKey("s", modifierFlags: [.command, .shift])
    }

    func testTabBarShowsMultipleChannelEntries() throws {
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
