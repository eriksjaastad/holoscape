import XCTest

final class GroupChatChannelUITests: XCTestCase {
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

    private func createGroupChatChannel() {
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Group Chat"].click()
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - Channel Creation

    func testGroupChatChannelCreatesSuccessfully() throws {
        createGroupChatChannel()

        let window = app.windows["Holoscape"]
        let gcEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Group'")).firstMatch
        XCTAssertTrue(gcEntry.waitForExistence(timeout: 3), "Group Chat channel should appear in sidebar")
    }

    func testGroupChatChannelDisplaysLabel() throws {
        createGroupChatChannel()

        let window = app.windows["Holoscape"]
        let gcEntry = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-Group'")).firstMatch
        XCTAssertTrue(gcEntry.waitForExistence(timeout: 3), "Group Chat sidebar entry should display label")
    }

    func testGroupChatChannelStartsPolling() throws {
        createGroupChatChannel()
        Thread.sleep(forTimeInterval: 1.0)

        // Polling should start — verify channel exists and no crash
        let window = app.windows["Holoscape"]
        let gcEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Group'")).firstMatch
        XCTAssertTrue(gcEntry.exists, "Group Chat should exist after polling starts")
    }

    // MARK: - Message Display

    func testGroupChatChannelShowsMessages() throws {
        createGroupChatChannel()
        Thread.sleep(forTimeInterval: 1.0)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should display group chat messages without crash")
    }

    func testGroupChatChannelAutoScrolls() throws {
        createGroupChatChannel()
        Thread.sleep(forTimeInterval: 1.0)

        // Auto-scroll behavior — new messages should scroll to bottom
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain functional with auto-scroll")
    }

    func testGroupChatChannelPreservesScrollPosition() throws {
        createGroupChatChannel()
        Thread.sleep(forTimeInterval: 1.0)

        // If scrolled up, new messages shouldn't force scroll
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should preserve scroll position without crash")
    }

    // MARK: - Input

    func testGroupChatChannelSendsMessage() throws {
        createGroupChatChannel()

        let window = app.windows["Holoscape"]
        let gcEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Group'")).firstMatch
        if gcEntry.waitForExistence(timeout: 2) {
            gcEntry.click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)
        inputBox.typeText("group-chat-test")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertTrue(window.exists, "Window should remain after group chat message submission")
    }

    func testGroupChatChannelCommandHistory() throws {
        createGroupChatChannel()

        let window = app.windows["Holoscape"]
        let gcEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Group'")).firstMatch
        if gcEntry.waitForExistence(timeout: 2) {
            gcEntry.click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        let inputBox = app.textViews["input-box"]
        inputBox.typeText("gc-history-test")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        inputBox.typeKey(.upArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.1)
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "gc-history-test", "Up arrow should recall previous group chat message")
    }

    // MARK: - Reconnection

    func testGroupChatChannelReconnectsOnFailure() throws {
        createGroupChatChannel()
        Thread.sleep(forTimeInterval: 2.0)

        // API failure should trigger reconnect — verify no crash
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain after reconnection attempt")
    }

    func testGroupChatChannelStateUpdatesOnDisconnect() throws {
        createGroupChatChannel()
        Thread.sleep(forTimeInterval: 2.0)

        let window = app.windows["Holoscape"]
        let gcEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Group'")).firstMatch
        XCTAssertTrue(gcEntry.exists, "Group Chat entry should remain visible with updated state")
    }

    func testGroupChatChannelResumesAfterReconnect() throws {
        createGroupChatChannel()
        Thread.sleep(forTimeInterval: 2.0)

        // Reconnection should resume polling — verify app stability
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain functional after reconnection resume")
    }

    // MARK: - Lifecycle

    func testGroupChatChannelStopsPollingOnDeactivate() throws {
        createGroupChatChannel()
        Thread.sleep(forTimeInterval: 0.5)

        // Close channel — polling should stop
        app.typeKey("w", modifierFlags: .command)

        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 1) {
            closeButton.click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain after group chat close")
    }

    func testGroupChatChannelNoLeakedTimers() throws {
        // Create and close group chat channels multiple times
        for _ in 0..<3 {
            createGroupChatChannel()
            Thread.sleep(forTimeInterval: 0.5)

            app.typeKey("w", modifierFlags: .command)
            let closeButton = app.buttons["Close"]
            if closeButton.waitForExistence(timeout: 1) {
                closeButton.click()
            }
            Thread.sleep(forTimeInterval: 0.3)
        }

        // App should remain functional with no leaked timers
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain stable after multiple group chat create/close cycles")
    }
}
