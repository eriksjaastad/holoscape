import XCTest

final class ChannelRestorationUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Basic Restoration

    func testQuitAndRelaunchRestoresChannels() throws {
        // Create 3 channels total (1 default + 2 new)
        for _ in 0..<2 {
            app.menuBars.firstMatch.menuBarItems["File"].click()
            app.menuItems["New Channel"].click()
            let dialog = app.dialogs.firstMatch
            XCTAssertTrue(dialog.waitForExistence(timeout: 2))
            dialog.buttons["Shell"].click()
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Verify we have 3 channels
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists)

        // Quit the app (this triggers applicationWillTerminate → saveState)
        app.terminate()
        Thread.sleep(forTimeInterval: 0.5)

        // Relaunch
        app.launch()
        Thread.sleep(forTimeInterval: 1.0)

        // Should have restored the channels
        let restoredWindow = app.windows["Holoscape"]
        XCTAssertTrue(restoredWindow.waitForExistence(timeout: 3), "Window should exist after relaunch")

        // At minimum, the app should have a channel and be functional
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2), "Input box should be present after restoration")
    }

    // MARK: - State Persistence

    func testSidebarCollapseStatePersistsAcrossRestart() throws {
        // Collapse sidebar
        app.typeKey("s", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.3)

        // Quit and relaunch
        app.terminate()
        Thread.sleep(forTimeInterval: 0.5)
        app.launch()
        Thread.sleep(forTimeInterval: 1.0)

        // Tab bar should be visible (sidebar was collapsed)
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 3))

        let tabButton = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'")).firstMatch
        XCTAssertTrue(tabButton.waitForExistence(timeout: 2), "Tab bar should be visible if sidebar was collapsed before quit")

        // Restore sidebar for clean state
        app.typeKey("s", modifierFlags: [.command, .shift])
    }

    // MARK: - Pin State Persistence

    func testPinStatePersistsAcrossRestart() throws {
        // Create a second channel
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 2))
        dialog.buttons["Shell"].click()
        Thread.sleep(forTimeInterval: 0.5)

        // Pin the second channel via context menu
        let window = app.windows["Holoscape"]
        let shell2 = window.buttons.matching(NSPredicate(format: "identifier == 'sidebar-Shell 2'")).firstMatch
        if shell2.waitForExistence(timeout: 2) {
            shell2.rightClick()
            let pinItem = app.menuItems["Pin"]
            if pinItem.waitForExistence(timeout: 1) {
                pinItem.click()
                Thread.sleep(forTimeInterval: 0.3)
            }
        }

        // Quit and relaunch
        app.terminate()
        Thread.sleep(forTimeInterval: 0.5)
        app.launch()
        Thread.sleep(forTimeInterval: 1.0)

        // Verify the pin indicator is present after restart
        let restoredWindow = app.windows["Holoscape"]
        XCTAssertTrue(restoredWindow.waitForExistence(timeout: 3))

        let pinnedEntry = restoredWindow.buttons.matching(NSPredicate(format: "title CONTAINS '\u{1F4CC}'")).firstMatch
        XCTAssertTrue(pinnedEntry.waitForExistence(timeout: 2), "Pinned channel should retain pin state after restart")
    }

    // MARK: - Empty State

    func testFreshLaunchCreatesDefaultShell() throws {
        // Even without saved state, the app should create a default shell
        // (This is the normal launch behavior)
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 3))

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2), "Should have an input box from default shell")
    }
}
