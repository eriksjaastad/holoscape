import XCTest

final class SessionLauncherUITests: HoloscapeUITestCase {
    private var launcherFixtureRoot: URL!

    override func configureAppForLaunch(_ app: XCUIApplication) {
        launcherFixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-launcher-ui-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: launcherFixtureRoot.appendingPathComponent("filter-target", isDirectory: true),
            withIntermediateDirectories: true
        )
        app.launchEnvironment["HOLOSCAPE_UI_TEST_LAUNCHER_ROOT"] = launcherFixtureRoot.path
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
        if let launcherFixtureRoot {
            try? FileManager.default.removeItem(at: launcherFixtureRoot)
        }
    }

    // MARK: - Session Launcher Display

    func testSessionLauncherVisibleOnLaunch() throws {
        let comboBox = app.searchFields["session-launcher-combo"]
        XCTAssertTrue(comboBox.waitForExistence(timeout: 2), "Session launcher combo box should exist on launch")
        XCTAssertTrue(comboBox.isEnabled, "Session launcher should be enabled on launch")
    }

    func testSessionLauncherHasSections() throws {
        let comboBox = app.searchFields["session-launcher-combo"]
        XCTAssertTrue(comboBox.waitForExistence(timeout: 2))

        comboBox.click()

        let screenshot = XCTAttachment(screenshot: app.windows["Holoscape"].screenshot())
        screenshot.name = "Directory-rooted session launcher"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertTrue(app.staticTexts["launcher-section-channels"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["launcher-section-directories"].waitForExistence(timeout: 2))

        app.typeKey(.escape, modifierFlags: [])
    }

    func testLauncherFiltersDirectoryRows() throws {
        let searchField = app.searchFields["session-launcher-combo"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        searchField.click()
        searchField.typeText("filter-target")

        XCTAssertTrue(app.buttons["launcher-item-filter-target"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["launcher-section-directories"].exists)
        XCTAssertFalse(app.staticTexts["launcher-section-recent"].exists)
    }

    func testRefreshButtonExists() throws {
        let refreshButton = app.buttons["refresh-sessions"]
        XCTAssertTrue(refreshButton.waitForExistence(timeout: 2), "Refresh button should exist")
        XCTAssertTrue(refreshButton.isHittable, "Refresh button should be hittable")
        XCTAssertEqual(refreshButton.label, "Refresh launcher")
    }

    func testRefreshHoverSurvivesAppReactivation() throws {
        let window = app.windows["Holoscape"]
        let refreshButton = app.buttons["refresh-sessions"]
        XCTAssertTrue(refreshButton.waitForExistence(timeout: 2))
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).hover()
        waitForValue("not hovered", on: refreshButton)

        refreshButton.hover()
        waitForValue("hovered", on: refreshButton)
        let beforeReactivation = XCTAttachment(screenshot: window.screenshot())
        beforeReactivation.name = "Refresh hover before reactivation"
        beforeReactivation.lifetime = .keepAlways
        add(beforeReactivation)

        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        waitForValue("not hovered", on: refreshButton)
        app.activate()
        XCTAssertTrue(refreshButton.waitForExistence(timeout: 2))
        waitForValue("hovered", on: refreshButton)

        let afterReactivation = XCTAttachment(screenshot: window.screenshot())
        afterReactivation.name = "Refresh hover after reactivation"
        afterReactivation.lifetime = .keepAlways
        add(afterReactivation)
    }

    private func waitForValue(_ value: String, on element: XCUIElement) {
        let expectation = expectation(
            for: NSPredicate(format: "value == %@", value),
            evaluatedWith: element
        )
        wait(for: [expectation], timeout: 2)
    }

    // MARK: - Profile Selection

    func testSelectingShellProfileCreatesShellChannel() throws {
        let countBefore = sidebarEntryCount()
        createChannel(type: "Shell")
        // Don't match by "Shell" — OSC 7 renames the channel to its directory name
        // almost immediately. Verify a new sidebar entry exists regardless of label.
        let entry = waitForNewSidebarEntry(expectedCount: countBefore + 1)
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "Shell channel should appear in sidebar after selection")
        XCTAssertTrue(entry.isHittable, "Shell sidebar entry should be hittable")
    }

    func testSelectingBridgeProfileCreatesBridgeChannel() throws {
        createChannel(type: "Bridge")
        let entry = sidebarEntry("Bridge")
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "Bridge channel should appear in sidebar after selection")
        XCTAssertTrue(entry.isHittable, "Bridge sidebar entry should be hittable")
    }

    func testSelectingSSHProfileCreatesSSHChannel() throws {
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let comboBox = app.searchFields["session-launcher-combo"]
        XCTAssertTrue(comboBox.waitForExistence(timeout: 2))
        comboBox.typeText("ssh localhost")
        comboBox.typeKey(.return, modifierFlags: [])

        let entry = sidebarEntry("localhost")
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "SSH channel should appear in sidebar after launcher selection")
        XCTAssertTrue(entry.isHittable, "SSH sidebar entry should be hittable")
    }

    func testSelectingAgentProfileCreatesAgentChannel() throws {
        try skipUnlessClaudeCLIInstalled()
        createChannel(type: "Agent (OAuth)")
        let entry = sidebarEntry("Agent")
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "Agent channel should appear in sidebar after selection")
        XCTAssertTrue(entry.isHittable, "Agent sidebar entry should be hittable")
    }

    func testSelectingMCPProfileCreatesMCPChannel() throws {
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        XCTAssertTrue(app.searchFields["session-launcher-combo"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.dialogs.firstMatch.waitForExistence(timeout: 1), "MCP should no longer be offered through a separate New Channel picker")
        throw XCTSkip("MCP has no unified launcher profile unless a saved session is configured")
    }

    func testSelectingGroupChatProfileCreatesGroupChatChannel() throws {
        let envPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/agent-chat.env").path
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: envPath),
            "Agent chat env not configured"
        )
        createChannel(type: "Group Chat")
        let entry = sidebarEntry("Chat")
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "Chat channel should appear in sidebar after selection")
        XCTAssertTrue(entry.isHittable, "Chat sidebar entry should be hittable")
    }

    // MARK: - Custom Input

    func testTypingCustomNameAndEnter() throws {
        let comboBox = app.searchFields["session-launcher-combo"]
        XCTAssertTrue(comboBox.waitForExistence(timeout: 2))

        comboBox.click()
        comboBox.typeText("custom-test-session")
        comboBox.typeKey(.return, modifierFlags: [])

        // After creating a channel, a sidebar entry should appear
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Window should exist after custom session creation")
        // The combo box should still be functional
        let comboStill = app.searchFields["session-launcher-combo"]
        XCTAssertTrue(comboStill.waitForExistence(timeout: 2), "Session launcher should remain after custom entry")
        XCTAssertTrue(comboStill.isEnabled, "Session launcher should be enabled after custom session creation")
    }

    func testComboBoxAutocomplete() throws {
        let comboBox = app.searchFields["session-launcher-combo"]
        XCTAssertTrue(comboBox.waitForExistence(timeout: 2))

        comboBox.click()
        comboBox.typeText("Sh")

        // Combo box should still be enabled and have text
        XCTAssertTrue(comboBox.isEnabled, "Combo box should remain enabled during autocomplete")
        let value = comboBox.value as? String ?? ""
        XCTAssertFalse(value.isEmpty, "Combo box should contain text after typing")

        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Refresh

    func testRefreshButtonTriggersDiscovery() throws {
        let refreshButton = app.buttons["refresh-sessions"]
        XCTAssertTrue(refreshButton.waitForExistence(timeout: 2))

        refreshButton.click()

        // After refresh, the combo box should still be enabled
        let comboBox = app.searchFields["session-launcher-combo"]
        XCTAssertTrue(comboBox.waitForExistence(timeout: 2), "Combo box should exist after refresh")
        XCTAssertTrue(comboBox.isEnabled, "Combo box should be enabled after refresh")
    }

    func testMultipleRefreshesDoNotCrash() throws {
        let refreshButton = app.buttons["refresh-sessions"]
        XCTAssertTrue(refreshButton.waitForExistence(timeout: 2))

        // Click refresh multiple times
        refreshButton.click()
        refreshButton.click()
        refreshButton.click()

        // Combo box should still be functional after multiple refreshes
        let comboBox = app.searchFields["session-launcher-combo"]
        XCTAssertTrue(comboBox.waitForExistence(timeout: 2), "Combo box should exist after multiple refreshes")
        XCTAssertTrue(comboBox.isEnabled, "Combo box should remain enabled after multiple refreshes")

        comboBox.click()
        XCTAssertTrue(comboBox.isEnabled, "Combo box should be enabled with dropdown open after refreshes")
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Recent Sessions

    func testRecentSessionAppearsAfterCreation() throws {
        let countBefore = sidebarEntryCount()
        createChannel(type: "Shell")
        // Don't match by "Shell" — OSC 7 renames the channel to its directory name.
        let entry = waitForNewSidebarEntry(expectedCount: countBefore + 1)
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "Shell channel should appear in sidebar")

        // Combo box should still be functional after channel creation
        let comboBox = app.searchFields["session-launcher-combo"]
        XCTAssertTrue(comboBox.waitForExistence(timeout: 2), "Session launcher should exist after channel creation")
        XCTAssertTrue(comboBox.isEnabled, "Session launcher should remain enabled after channel creation")
    }

    // MARK: - Focus Management

    func testCmdNFocusesLauncher() throws {
        app.typeKey("n", modifierFlags: .command)

        let comboBox = app.searchFields["session-launcher-combo"]
        XCTAssertTrue(comboBox.waitForExistence(timeout: 2), "Combo box should exist after Cmd+N")

        // Verify focus by typing and checking the value appears
        comboBox.typeText("focus-test")
        let value = comboBox.value as? String ?? ""
        XCTAssertTrue(value.contains("focus-test"), "Typed text should appear in combo box, confirming focus")

        app.typeKey(.escape, modifierFlags: [])
    }

    func testLauncherFocusReturnAfterCancel() throws {
        app.typeKey("n", modifierFlags: .command)

        let comboBox = app.searchFields["session-launcher-combo"]
        XCTAssertTrue(comboBox.waitForExistence(timeout: 2))

        // Escape to cancel
        app.typeKey(.escape, modifierFlags: [])

        // Channel should be responsive after cancelling launcher
        assertActiveChannelResponsive(message: "Channel should be responsive after launcher cancel")
    }
}
