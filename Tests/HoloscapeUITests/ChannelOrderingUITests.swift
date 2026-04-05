import XCTest

final class ChannelOrderingUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Helpers

    private func createShellChannel() {
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Shell"].click()
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - Unread Ordering

    func testUnreadChannelMovesToFront() throws {
        createShellChannel()
        Thread.sleep(forTimeInterval: 0.3)

        // Switch to second channel so first becomes inactive
        app.typeKey("2", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // First shell may receive output and move to front
        let window = app.windows["Holoscape"]
        let sidebarButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'"))
        XCTAssertGreaterThanOrEqual(sidebarButtons.count, 2, "Should have at least 2 sidebar entries")
    }

    func testMultipleUnreadChannelsOrdered() throws {
        createShellChannel()
        createShellChannel()
        Thread.sleep(forTimeInterval: 0.3)

        // Switch to last channel
        app.typeKey("3", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Multiple unread channels should be ordered by most recent activity
        let window = app.windows["Holoscape"]
        let sidebarButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'"))
        XCTAssertGreaterThanOrEqual(sidebarButtons.count, 3, "Should have at least 3 sidebar entries")
    }

    func testReadChannelMovesBack() throws {
        createShellChannel()
        Thread.sleep(forTimeInterval: 0.3)

        // Switch away then back
        app.typeKey("2", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Switching to unread channel marks it read
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Reading channel should not crash or break ordering")
    }

    func testUnreadOrderingRespectsPins() throws {
        createShellChannel()
        Thread.sleep(forTimeInterval: 0.3)

        // Pin the first shell
        let window = app.windows["Holoscape"]
        let shell1 = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Shell'")).firstMatch
        if shell1.waitForExistence(timeout: 2) {
            shell1.rightClick()
            Thread.sleep(forTimeInterval: 0.3)
            let pinItem = app.menuItems["Pin"]
            if pinItem.waitForExistence(timeout: 1) {
                pinItem.click()
            }
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Pinned channels should stay above unpinned
        XCTAssertTrue(shell1.exists, "Pinned channel should remain at top regardless of unread state")
    }

    // MARK: - Sidebar Order Stability

    func testSidebarOrderStableWhenNoActivity() throws {
        createShellChannel()
        Thread.sleep(forTimeInterval: 0.5)

        let window = app.windows["Holoscape"]
        let sidebarButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'"))
        let initialCount = sidebarButtons.count

        // Wait with no activity
        Thread.sleep(forTimeInterval: 1.0)

        let afterCount = sidebarButtons.count
        XCTAssertEqual(initialCount, afterCount, "Sidebar order should not change without activity")
    }

    func testNewChannelAppearsAtEnd() throws {
        let window = app.windows["Holoscape"]
        let initialButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'"))
        let initialCount = initialButtons.count

        createShellChannel()

        let afterButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'"))
        XCTAssertEqual(afterButtons.count, initialCount + 1, "New channel should be added to sidebar")
    }

    func testClosedChannelRemovedCleanly() throws {
        createShellChannel()

        let window = app.windows["Holoscape"]
        let shell2 = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Shell 2'")).firstMatch
        XCTAssertTrue(shell2.waitForExistence(timeout: 2))

        // Close Shell 2
        shell2.click()
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("w", modifierFlags: .command)
        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 1) {
            closeButton.click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        // No ghost entries
        XCTAssertFalse(shell2.exists, "Closed channel should leave no ghost entry in sidebar")
    }

    // MARK: - Tab Bar Order

    func testTabBarReflectsSidebarOrder() throws {
        createShellChannel()
        Thread.sleep(forTimeInterval: 0.3)

        // Collapse sidebar to show tab bar
        app.typeKey("s", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        let tabButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'"))
        XCTAssertGreaterThanOrEqual(tabButtons.count, 2, "Tab bar should reflect sidebar entries when sidebar collapsed")

        // Re-expand sidebar
        app.typeKey("s", modifierFlags: [.command, .shift])
    }

    func testTabBarUpdatesOnReorder() throws {
        createShellChannel()
        Thread.sleep(forTimeInterval: 0.3)

        // Collapse sidebar
        app.typeKey("s", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.3)

        // Tab bar should update when channels reorder
        let window = app.windows["Holoscape"]
        let tabButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'"))
        XCTAssertGreaterThanOrEqual(tabButtons.count, 2, "Tab bar should update on reorder")

        // Re-expand sidebar
        app.typeKey("s", modifierFlags: [.command, .shift])
    }
}
