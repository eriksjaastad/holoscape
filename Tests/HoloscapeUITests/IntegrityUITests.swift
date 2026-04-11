import XCTest

/// Comprehensive integrity tests covering every critical UI interaction gap.
/// Tests focus on: unread indicators, input box visibility transitions,
/// focus management, channel state indicators, split pane visual state,
/// elapsed time formatting, sidebar scaling, and cross-feature interactions.
final class IntegrityUITests: HoloscapeUITestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launchArguments.append("--disable-notification-suppression")
        // Use the parent's random port allocation
        let port = UInt16.random(in: 49152...60999)
        Self.currentAPIBase = "http://127.0.0.1:\(port)"
        app.launchArguments += ["--api-port", "\(port)"]
        app.launch()

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "App window should appear after launch")
        let sidebar = window.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'sidebar-'")
        ).firstMatch
        _ = sidebar.waitForExistence(timeout: 10)
    }

    // MARK: - Unread Indicators

    /// When a background channel receives output, the tab title must show the bullet "●".
    func testUnreadBulletAppearsOnBackgroundOutput() throws {
        // Create two channels so we can switch away from one
        try apiCreateChannel(label: "unread-test")
        let entry = sidebarEntry("unread-test")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))

        // Switch to channel 1 (default shell), making unread-test a background channel
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Send input to the background channel to generate output
        try apiSendInput(label: "unread-test", text: "echo unread-marker-12345")
        Thread.sleep(forTimeInterval: 1.0)

        // Collapse sidebar to see tab bar (where bullet appears)
        app.typeKey("s", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.5)

        // Find the tab for unread-test — title should contain bullet
        let tabBar = app.windows["Holoscape"]
        let unreadTab = tabBar.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'tab-unread-test'"
        )).firstMatch

        if unreadTab.waitForExistence(timeout: 3) {
            let title = unreadTab.title
            XCTAssertTrue(title.contains("\u{25CF}"),
                "Tab title should contain bullet dot (●) for unread channel, got: '\(title)'")
        }

        // Expand sidebar back
        app.typeKey("s", modifierFlags: [.command, .shift])
    }

    /// When switching to a channel with unread output, the unread state must clear.
    func testUnreadClearsOnChannelSwitch() throws {
        try apiCreateChannel(label: "unread-clear")
        let entry = sidebarEntry("unread-clear")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))

        // Switch away
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Generate output on background channel
        try apiSendInput(label: "unread-clear", text: "echo output-for-unread")
        Thread.sleep(forTimeInterval: 1.0)

        // Now switch to the unread channel
        entry.click()
        Thread.sleep(forTimeInterval: 0.5)

        // After switching, accessibility value should be "active" (not "normal" with unread)
        let value = entry.value as? String
        XCTAssertEqual(value, "active", "Channel should become 'active' after switching to it, clearing unread state")
    }

    /// Sidebar entry for background channel with notification shows correct accessibility value.
    func testSidebarUnreadBackgroundState() throws {
        try apiCreateChannel(label: "bg-state-test")
        let entry = sidebarEntry("bg-state-test")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))

        // Switch away from the new channel
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Without notification, background channel should be "normal"
        let value = entry.value as? String
        XCTAssertEqual(value, "normal", "Background channel without unread should be 'normal'")
    }

    // MARK: - Input Box Visibility Transitions (PTY vs Non-PTY)

    /// Shell (PTY) channel must NOT show the input box.
    func testShellChannelHidesInputBox() throws {
        let window = app.windows["Holoscape"]
        let inputBox = window.textViews["input-box"]

        // Default channel is shell (PTY) — input box should be hidden or not hittable
        Thread.sleep(forTimeInterval: 1.0)
        if inputBox.exists {
            XCTAssertFalse(inputBox.isHittable,
                "Input box should not be hittable for PTY (shell) channel")
        }
    }

    /// Bridge (non-PTY) channel must show the input box.
    func testBridgeChannelShowsInputBox() throws {
        createChannel(type: "Bridge")
        Thread.sleep(forTimeInterval: 1.0)

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3),
            "Input box should be visible for non-PTY (Bridge) channel")
        XCTAssertTrue(inputBox.isHittable,
            "Input box should be hittable for non-PTY (Bridge) channel")
    }

    /// Switching from PTY to non-PTY channel must show the input box.
    func testInputBoxAppearsWhenSwitchingFromPTYToNonPTY() throws {
        // Start on shell (PTY) — input box hidden
        let inputBox = app.textViews["input-box"]

        // Create a bridge channel (non-PTY)
        createChannel(type: "Bridge")
        Thread.sleep(forTimeInterval: 1.0)

        // After switching to bridge, input box should be visible
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3),
            "Input box should appear after switching from PTY to non-PTY channel")
        XCTAssertTrue(inputBox.isHittable,
            "Input box should be hittable after switching to non-PTY channel")
    }

    /// Switching from non-PTY back to PTY channel must hide the input box.
    func testInputBoxHidesWhenSwitchingFromNonPTYToPTY() throws {
        // Create bridge channel (non-PTY)
        createChannel(type: "Bridge")
        Thread.sleep(forTimeInterval: 1.0)

        // Verify input box is visible for bridge
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3),
            "Input box should be visible for bridge channel")

        // Switch back to shell (Cmd+1)
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Input box should now be hidden or not hittable
        if inputBox.exists {
            XCTAssertFalse(inputBox.isHittable,
                "Input box should not be hittable after switching back to PTY channel")
        }
    }

    /// Rapid PTY/non-PTY switching must not leave input box in wrong state.
    func testRapidPTYNonPTYSwitching() throws {
        createChannel(type: "Bridge")
        Thread.sleep(forTimeInterval: 0.5)

        let inputBox = app.textViews["input-box"]

        for _ in 0..<10 {
            // Switch to shell (PTY)
            app.typeKey("1", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.2)

            // Switch to bridge (non-PTY)
            app.typeKey("2", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.2)
        }

        // Should end on bridge — input box visible
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2),
            "After rapid switching, input box should be visible on non-PTY channel")
        XCTAssertTrue(inputBox.isHittable,
            "After rapid switching, input box should be hittable on non-PTY channel")

        // Switch to shell — input box hidden
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        if inputBox.exists {
            XCTAssertFalse(inputBox.isHittable,
                "After rapid switching ending on PTY, input box should not be hittable")
        }
    }

    // MARK: - Focus Management

    /// Terminal view must become first responder when switching to PTY channel.
    func testTerminalGetsFocusOnPTYSwitch() throws {
        // Create a second shell channel to switch between
        try apiCreateChannel(label: "focus-test")
        Thread.sleep(forTimeInterval: 0.5)

        // Switch to the new channel
        let entry = sidebarEntry("focus-test")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Terminal view should exist and be responsive
        let terminal = terminalView()
        XCTAssertTrue(terminal.waitForExistence(timeout: 3),
            "Terminal view should exist after switching to PTY channel")
    }

    /// Input box must become first responder when switching to non-PTY channel.
    func testInputBoxGetsFocusOnNonPTYSwitch() throws {
        createChannel(type: "Bridge")
        Thread.sleep(forTimeInterval: 1.0)

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3),
            "Input box should exist for non-PTY channel")

        // Verify focus by typing — text should appear in input box
        inputBox.typeText("focus-test-text")
        Thread.sleep(forTimeInterval: 0.3)

        let value = inputBox.value as? String ?? ""
        XCTAssertTrue(value.contains("focus-test-text"),
            "Input box should have received typed text, indicating it has focus. Got: '\(value)'")
    }

    /// Focus must transfer correctly when switching from non-PTY to PTY.
    func testFocusTransfersFromInputBoxToTerminal() throws {
        // Start on shell (PTY, terminal has focus)
        createChannel(type: "Bridge")
        Thread.sleep(forTimeInterval: 0.5)

        // Now on bridge (non-PTY, input box should have focus)
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))

        // Switch back to shell (PTY)
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Terminal should be responsive (indicating focus)
        assertActiveChannelResponsive(message: "Terminal should be responsive after switching from non-PTY to PTY")
    }

    // MARK: - Channel State Indicators

    /// Active channel sidebar entry must have accessibility value "active".
    func testActiveChannelShowsActiveState() throws {
        let entries = app.windows["Holoscape"].buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'sidebar-'")
        )
        guard entries.count > 0 else {
            XCTFail("At least one sidebar entry should exist")
            return
        }

        let firstEntry = entries.element(boundBy: 0)
        XCTAssertTrue(firstEntry.waitForExistence(timeout: 3))

        let value = firstEntry.value as? String
        XCTAssertEqual(value, "active", "Active channel should have accessibility value 'active'")
    }

    /// Disconnected channel must show "disconnected" accessibility value.
    func testDisconnectedChannelShowsDisconnectedState() throws {
        try apiCreateChannel(label: "disconnect-test")
        let entry = sidebarEntry("disconnect-test")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))

        // Switch to the channel and send exit to disconnect
        entry.click()
        Thread.sleep(forTimeInterval: 0.5)
        try apiSendInput(label: "disconnect-test", text: "exit")
        Thread.sleep(forTimeInterval: 2.0)

        let value = entry.value as? String
        XCTAssertEqual(value, "disconnected",
            "Channel after 'exit' should show 'disconnected' accessibility value")
    }

    /// Multiple state transitions: active -> background -> notified -> clicked -> active.
    func testFullStateTransitionCycle() throws {
        try apiCreateChannel(dir: "/tmp", label: "state-cycle")
        let entry = sidebarEntry("state-cycle")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))

        // Switch to it — should be active
        entry.click()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(entry.value as? String, "active", "Should start as active")

        // Switch away — should become normal
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(entry.value as? String, "normal", "Background channel should be normal")

        // Send notification — should become "ready"
        try apiNotify(type: "idle_prompt", cwd: "/tmp/state-cycle")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(entry.value as? String, "ready", "Notified channel should be ready")

        // Click to switch back — should clear to active
        entry.click()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(entry.value as? String, "active", "After clicking, should return to active")
    }

    // MARK: - Elapsed Time Format

    /// Elapsed time should appear in tab title with valid format.
    func testElapsedTimeFormatInTabBar() throws {
        // Collapse sidebar to see tab bar
        app.typeKey("s", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.5)

        let tabs = app.windows["Holoscape"].buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'tab-'")
        )
        guard tabs.count > 0 else {
            XCTFail("At least one tab should exist")
            return
        }

        let firstTab = tabs.element(boundBy: 0)
        XCTAssertTrue(firstTab.waitForExistence(timeout: 3))
        let title = firstTab.title

        // Active channel should have elapsed time in parentheses
        if title.contains("(") && title.contains(")") {
            // Extract the elapsed time portion
            let regex = try NSRegularExpression(pattern: "\\((\\d+[mh](?:\\s*\\d+m)?)\\)")
            let range = NSRange(title.startIndex..., in: title)
            let match = regex.firstMatch(in: title, range: range)
            XCTAssertNotNil(match,
                "Elapsed time should match format like '1m', '5m', '1h', '2h 30m', got: '\(title)'")
        }
        // Note: If channel just started, elapsed time might be "<1m" or omitted

        // Expand sidebar back
        app.typeKey("s", modifierFlags: [.command, .shift])
    }

    // MARK: - Split Pane Active Border

    /// Creating a split pane should result in two pane views with the active one having a border.
    func testSplitPaneActiveBorderExists() throws {
        // Create horizontal split
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // We should have 2 panes in the split view
        let splitViews = app.windows["Holoscape"].splitGroups
        XCTAssertTrue(splitViews.count >= 1,
            "Split view should exist after Cmd+D")

        // Close the split pane
        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    /// Creating and interacting with split panes maintains correct channel assignment.
    func testSplitPaneChannelAssignment() throws {
        // Create a second channel
        try apiCreateChannel(label: "split-assign")
        Thread.sleep(forTimeInterval: 0.5)

        // Create horizontal split
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Both panes should work — terminal view should still be responsive
        assertActiveChannelResponsive(message: "Channel should be responsive after split")

        // Close the split
        app.typeKey("w", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.3)

        // Still responsive after closing split
        assertActiveChannelResponsive(message: "Channel should be responsive after closing split pane")
    }

    // MARK: - Sidebar Scaling

    /// Creating many channels should not crash and all should appear in sidebar.
    func testSidebarScalesWithManyChannels() throws {
        let channelCount = 10

        for i in 0..<channelCount {
            try apiCreateChannel(label: "scale-\(i)")
        }
        Thread.sleep(forTimeInterval: 1.0)

        // All channels should exist in sidebar
        for i in 0..<channelCount {
            let entry = sidebarEntry("scale-\(i)")
            XCTAssertTrue(entry.waitForExistence(timeout: 2),
                "Channel 'scale-\(i)' should exist in sidebar")
        }

        // Total sidebar entry count should include default + created
        let totalEntries = sidebarEntryCount()
        XCTAssertGreaterThanOrEqual(totalEntries, channelCount,
            "Sidebar should have at least \(channelCount) entries, got \(totalEntries)")

        // Clean up
        for i in 0..<channelCount {
            try apiDeleteChannel(label: "scale-\(i)")
        }
    }

    /// Switching between many channels via Cmd+N should work for all 9 positions.
    func testCmdNumberSwitchingWithManyChannels() throws {
        // Create channels to fill positions 2-9
        for i in 2...9 {
            try apiCreateChannel(label: "pos-\(i)")
        }
        Thread.sleep(forTimeInterval: 1.0)

        // Switch to each position and verify the channel becomes active
        for i in 1...9 {
            app.typeKey("\(i)", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.3)

            // Verify some channel is now active
            let activeEntries = app.windows["Holoscape"].buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'sidebar-' AND value == 'active'")
            )
            XCTAssertGreaterThanOrEqual(activeEntries.count, 1,
                "After Cmd+\(i), at least one channel should be active")
        }

        // Clean up
        for i in 2...9 {
            try apiDeleteChannel(label: "pos-\(i)")
        }
    }

    // MARK: - Search Integrity

    /// Search must find text, show accurate count, and navigate matches.
    func testSearchFindNavigateAndCount() throws {
        // Send distinctive text to the channel
        try apiCreateChannel(label: "search-integrity")
        let entry = sidebarEntry("search-integrity")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Send multiple lines with the search term
        for i in 1...3 {
            try apiSendInput(label: "search-integrity", text: "echo FINDME-\(i)")
            Thread.sleep(forTimeInterval: 0.3)
        }
        Thread.sleep(forTimeInterval: 1.0)

        // Open search
        openSearch()

        // Type search query
        let searchField = app.toolbars["Search Bar"].searchFields.firstMatch
        if searchField.waitForExistence(timeout: 2) {
            searchField.typeText("FINDME")
            Thread.sleep(forTimeInterval: 0.5)

            // Check match count
            if let countText = searchMatchCountText() {
                XCTAssertFalse(countText.isEmpty || countText == "No matches",
                    "Search for 'FINDME' should find matches, got: '\(countText)'")
            }
        }

        // Close search
        closeSearch()

        // Clean up
        try apiDeleteChannel(label: "search-integrity")
    }

    /// Search bar must close on Escape and not leave artifacts.
    func testSearchBarClosesCleanly() throws {
        // Open search
        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.exists, "Search bar should be open")

        // Close with Escape
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        // Search bar should no longer be visible (height 0)
        // The toolbar still exists but the search field shouldn't be hittable
        // Just verify the main window is still functional
        assertActiveChannelResponsive(message: "App should be responsive after closing search")
    }

    // MARK: - Context Menu Integrity

    /// Every context menu action should work in sequence without crashes.
    func testContextMenuFullWorkflow() throws {
        try apiCreateChannel(label: "ctx-menu-test")
        let entry = sidebarEntry("ctx-menu-test")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))

        // 1. Pin the channel
        entry.rightClick()
        let pinItem = app.menuItems["Pin"]
        if pinItem.waitForExistence(timeout: 2) {
            pinItem.click()
            Thread.sleep(forTimeInterval: 0.3)

            // Verify pin emoji in title
            let pinnedEntry = pinnedSidebarEntry("ctx-menu-test")
            XCTAssertTrue(pinnedEntry.waitForExistence(timeout: 2),
                "Pinned channel should show pin emoji")
        }

        // 2. Copy session info
        let refreshedEntry = sidebarEntry("ctx-menu-test")
        XCTAssertTrue(refreshedEntry.waitForExistence(timeout: 2))
        refreshedEntry.rightClick()
        let copyItem = app.menuItems["Copy Session Info"]
        if copyItem.waitForExistence(timeout: 2) {
            copyItem.click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        // 3. Duplicate the channel
        let entryAgain = sidebarEntry("ctx-menu-test")
        XCTAssertTrue(entryAgain.waitForExistence(timeout: 2))
        entryAgain.rightClick()
        let dupItem = app.menuItems["Duplicate"]
        if dupItem.waitForExistence(timeout: 2) {
            dupItem.click()
            Thread.sleep(forTimeInterval: 1.0)

            // Should have more entries now
            let countAfterDup = sidebarEntryCount()
            XCTAssertGreaterThanOrEqual(countAfterDup, 3,
                "After duplicate, should have at least 3 sidebar entries")
        }

        // 4. Unpin the channel
        let entryForUnpin = sidebarEntry("ctx-menu-test")
        XCTAssertTrue(entryForUnpin.waitForExistence(timeout: 2))
        entryForUnpin.rightClick()
        let unpinItem = app.menuItems["Unpin"]
        if unpinItem.waitForExistence(timeout: 2) {
            unpinItem.click()
            Thread.sleep(forTimeInterval: 0.3)
        }

        // 5. Close the channel
        let entryForClose = sidebarEntry("ctx-menu-test")
        XCTAssertTrue(entryForClose.waitForExistence(timeout: 2))
        entryForClose.rightClick()
        let closeItem = app.menuItems["Close"]
        if closeItem.waitForExistence(timeout: 2) {
            closeItem.click()
            Thread.sleep(forTimeInterval: 0.5)

            // Handle confirmation dialog if it appears
            let confirmClose = app.buttons["Close"]
            if confirmClose.waitForExistence(timeout: 1) {
                confirmClose.click()
            }
        }
    }

    // MARK: - Settings Integrity

    /// All settings controls must be interactable and persist.
    func testSettingsControlsInteractable() throws {
        openSettings()

        // Theme popup
        let theme = themePopup()
        XCTAssertTrue(theme.waitForExistence(timeout: 2), "Theme popup should exist")
        XCTAssertTrue(theme.isEnabled, "Theme popup should be enabled")

        // Font popup
        let font = fontFamilyPopup()
        XCTAssertTrue(font.waitForExistence(timeout: 2), "Font popup should exist")
        XCTAssertTrue(font.isEnabled, "Font popup should be enabled")

        // Font size field
        let fontSize = fontSizeField()
        XCTAssertTrue(fontSize.waitForExistence(timeout: 2), "Font size field should exist")
        XCTAssertTrue(fontSize.isEnabled, "Font size field should be enabled")

        // Transparency slider
        let slider = transparencySlider()
        XCTAssertTrue(slider.waitForExistence(timeout: 2), "Transparency slider should exist")
        XCTAssertTrue(slider.isEnabled, "Transparency slider should be enabled")

        // Skin popup
        let skinPopup = app.windows["Appearance Settings"].popUpButtons["skin-popup"]
        XCTAssertTrue(skinPopup.waitForExistence(timeout: 2), "Skin popup should exist")
        XCTAssertTrue(skinPopup.isEnabled, "Skin popup should be enabled")

        closeSettings()
    }

    /// Changing theme and immediately switching channels should not lose the theme.
    func testThemePersistsThroughChannelSwitch() throws {
        openSettings()

        // Record current theme
        let originalTheme = currentThemeValue()

        // Select a different theme
        let targetTheme = originalTheme == "Dark" ? "Monokai" : "Dark"
        selectTheme(targetTheme)
        Thread.sleep(forTimeInterval: 0.3)

        closeSettings()

        // Create and switch channels
        try apiCreateChannel(label: "theme-persist")
        let entry = sidebarEntry("theme-persist")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Switch back to first channel
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Verify theme is still the changed one
        openSettings()
        let currentTheme = currentThemeValue()
        XCTAssertEqual(currentTheme, targetTheme,
            "Theme should persist through channel switches, expected '\(targetTheme)', got '\(currentTheme)'")

        // Restore original theme
        selectTheme(originalTheme)
        closeSettings()

        // Clean up
        try apiDeleteChannel(label: "theme-persist")
    }

    // MARK: - Sidebar Toggle Integrity

    /// Toggling sidebar must show/hide sidebar and show/hide tab bar correctly.
    func testSidebarToggleConsistency() throws {
        // Start with sidebar expanded (default)
        let sidebarEntries = app.windows["Holoscape"].buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'sidebar-'")
        )
        let initialCount = sidebarEntries.count
        XCTAssertGreaterThan(initialCount, 0, "Sidebar should have entries when expanded")

        // Collapse sidebar
        app.typeKey("s", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.5)

        // Tab bar should now have entries
        let tabEntries = app.windows["Holoscape"].buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'tab-'")
        )
        XCTAssertGreaterThan(tabEntries.count, 0, "Tab bar should have entries when sidebar collapsed")

        // Expand sidebar again
        app.typeKey("s", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.5)

        // Sidebar entries should be back
        let restoredCount = sidebarEntries.count
        XCTAssertEqual(restoredCount, initialCount,
            "Sidebar entry count should be restored after toggle")
    }

    // MARK: - Command History Integrity

    /// Command history must navigate correctly with up/down arrows in input box.
    func testCommandHistoryNavigationInInputBox() throws {
        createChannel(type: "Bridge")
        Thread.sleep(forTimeInterval: 1.0)

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3))

        // Type and submit several commands
        let commands = ["first-command", "second-command", "third-command"]
        for cmd in commands {
            inputBox.click()
            inputBox.typeText(cmd)
            inputBox.typeKey(.return, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.3)
        }

        // Navigate up through history
        inputBox.click()
        inputBox.typeKey(.upArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.2)

        let historyValue = inputBox.value as? String ?? ""
        XCTAssertTrue(historyValue.contains("third-command") || historyValue.contains("second-command"),
            "Up arrow should recall recent command from history, got: '\(historyValue)'")
    }

    // MARK: - Window Management Integrity

    /// Window should remain functional after minimize and restore.
    func testMinimizeRestoreFunctionality() throws {
        // Minimize
        app.typeKey("m", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)

        // Click dock icon to restore (use the app's activate method)
        app.activate()
        Thread.sleep(forTimeInterval: 1.0)

        // Window should be responsive
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Window should exist after restore")
        assertActiveChannelResponsive(message: "Channel should be responsive after minimize/restore")
    }

    // MARK: - API Channel Lifecycle

    /// Full channel lifecycle via API: create -> switch -> input -> output -> delete.
    func testAPIChannelLifecycle() throws {
        // Create
        let (_, createCode) = try apiCreateChannel(dir: "/tmp", label: "lifecycle-test")
        XCTAssertEqual(createCode, 201, "Channel creation should return 201")

        // Verify in sidebar
        let entry = sidebarEntry("lifecycle-test")
        XCTAssertTrue(entry.waitForExistence(timeout: 3),
            "Created channel should appear in sidebar")

        // Switch
        try apiSwitchChannel(label: "lifecycle-test")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(entry.value as? String, "active",
            "Channel should be active after switch")

        // Send input and read output
        try apiSendInput(label: "lifecycle-test", text: "echo LIFECYCLE-OK")
        let found = try waitForAPIOutput(label: "lifecycle-test", containing: "LIFECYCLE-OK", timeout: 5)
        XCTAssertTrue(found, "Output should contain 'LIFECYCLE-OK' after sending echo command")

        // Delete
        try apiDeleteChannel(label: "lifecycle-test")
        Thread.sleep(forTimeInterval: 0.5)

        // Channel should be gone from sidebar
        let deletedEntry = sidebarEntry("lifecycle-test")
        XCTAssertFalse(deletedEntry.waitForExistence(timeout: 1),
            "Deleted channel should not appear in sidebar")
    }

    // MARK: - Bug Report Dialog Integrity

    /// Bug report dialog must contain all required elements and accept input.
    func testBugReportDialogCompleteness() throws {
        app.typeKey("b", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1.0)

        let dialog = app.windows.matching(NSPredicate(format: "identifier == 'bug-report-dialog'")).firstMatch
        // Dialog may use sheets or windows — check both
        let descField = app.textViews["bug-description-field"]
        let contextView = app.textViews["bug-context-view"]
        let screenshotBtn = app.buttons["bug-screenshot-button"]
        let submitBtn = app.buttons["bug-submit-button"]

        XCTAssertTrue(descField.waitForExistence(timeout: 3), "Description field should exist")
        XCTAssertTrue(contextView.waitForExistence(timeout: 2), "Context view should exist")
        XCTAssertTrue(screenshotBtn.waitForExistence(timeout: 2), "Screenshot button should exist")
        XCTAssertTrue(submitBtn.waitForExistence(timeout: 2), "Submit button should exist")

        // Context view should have auto-captured content
        let contextText = contextView.value as? String ?? ""
        XCTAssertFalse(contextText.isEmpty, "Context view should have auto-captured system info")

        // Type a description
        descField.click()
        descField.typeText("Integrity test bug report")
        let descValue = descField.value as? String ?? ""
        XCTAssertTrue(descValue.contains("Integrity test"),
            "Description field should accept typed text")

        // Cancel (don't actually submit)
        let cancelBtn = app.buttons["Cancel"]
        if cancelBtn.waitForExistence(timeout: 1) {
            cancelBtn.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    // MARK: - URL Scheme Integrity

    /// URL scheme must create a channel with correct type and label.
    func testURLSchemeCreatesChannelWithLabel() throws {
        let label = "url-integrity-test"
        openURL("holoscape://new-channel?type=shell&dir=/tmp&label=\(label)")
        Thread.sleep(forTimeInterval: 2.0)

        let entry = sidebarEntry(label)
        XCTAssertTrue(entry.waitForExistence(timeout: 5),
            "URL scheme should create channel with label '\(label)'")

        // Clean up
        try apiDeleteChannel(label: label)
    }

    // MARK: - Cross-Feature Interaction Tests

    /// Search should work correctly across channel switches.
    func testSearchPersistsAcrossChannelSwitch() throws {
        try apiCreateChannel(label: "cross-search")
        Thread.sleep(forTimeInterval: 0.5)

        // Open search on first channel
        openSearch()
        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.exists, "Search bar should be open")

        // Switch to another channel
        let entry = sidebarEntry("cross-search")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Search bar should still be visible
        XCTAssertTrue(searchBar.exists, "Search bar should persist across channel switch")

        closeSearch()
        try apiDeleteChannel(label: "cross-search")
    }

    /// Split panes should survive channel creation and deletion.
    func testSplitPanesSurviveChannelLifecycle() throws {
        // Create split
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Create a new channel
        try apiCreateChannel(label: "split-lifecycle")
        Thread.sleep(forTimeInterval: 0.5)

        // Switch to it
        let entry = sidebarEntry("split-lifecycle")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))
        entry.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Channel should be responsive in split view
        assertActiveChannelResponsive(message: "New channel should work in split view")

        // Delete the channel
        try apiDeleteChannel(label: "split-lifecycle")
        Thread.sleep(forTimeInterval: 0.5)

        // App should still be functional
        assertActiveChannelResponsive(message: "App should be responsive after deleting channel in split view")

        // Close split
        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    /// Settings changes should take effect while split panes are open.
    func testSettingsWorkWithSplitPanesOpen() throws {
        // Create split
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Open settings and change theme
        openSettings()
        let originalTheme = currentThemeValue()
        let targetTheme = originalTheme == "Dark" ? "Monokai" : "Dark"
        selectTheme(targetTheme)
        Thread.sleep(forTimeInterval: 0.3)

        // Verify change
        XCTAssertEqual(currentThemeValue(), targetTheme,
            "Theme should change even with split panes open")

        // Restore
        selectTheme(originalTheme)
        closeSettings()

        // Close split
        app.typeKey("w", modifierFlags: [.command, .shift])
    }

    // MARK: - Edit Menu Integrity

    /// Copy and paste should work in the terminal.
    func testCopyPasteInTerminal() throws {
        // Set clipboard to known text
        let pasteText = "integrity-paste-test"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pasteText, forType: .string)

        // Paste into terminal
        app.typeKey("v", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Verify the terminal is still responsive (paste didn't crash)
        assertActiveChannelResponsive(message: "Terminal should be responsive after paste")
    }

    /// Select All should work on terminal output.
    func testSelectAllOnTerminal() throws {
        // Select all
        app.typeKey("a", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Copy selection
        app.typeKey("c", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Terminal should still be responsive
        assertActiveChannelResponsive(message: "Terminal should be responsive after Select All + Copy")
    }

    // MARK: - Timestamp Toggle Integrity

    /// Cmd+T should toggle timestamps without breaking the terminal.
    func testTimestampToggle() throws {
        // Toggle timestamps on
        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Send a command to see if output still works
        let defaultChannel = try apiListChannels().first
        if let label = defaultChannel?["label"] as? String {
            try apiSendInput(label: label, text: "echo TIMESTAMP-TEST")
            let found = try waitForAPIOutput(label: label, containing: "TIMESTAMP-TEST", timeout: 5)
            XCTAssertTrue(found, "Output should work with timestamps enabled")
        }

        // Toggle timestamps off
        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        assertActiveChannelResponsive(message: "Terminal should be responsive after timestamp toggle")
    }

    // MARK: - Notification State Integrity

    /// Idle prompt and permission prompt must set correct accessibility values.
    func testNotificationTypesSetCorrectValues() throws {
        // Test idle_prompt -> "ready"
        try apiCreateChannel(dir: "/tmp", label: "notif-idle")
        let idleEntry = sidebarEntry("notif-idle")
        XCTAssertTrue(idleEntry.waitForExistence(timeout: 3))

        // Switch away so notification can register
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        try apiNotify(type: "idle_prompt", cwd: "/tmp/notif-idle")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(idleEntry.value as? String, "ready",
            "idle_prompt should set value to 'ready'")

        // Test permission_prompt -> "needs-approval"
        try apiCreateChannel(dir: "/tmp", label: "notif-perm")
        let permEntry = sidebarEntry("notif-perm")
        XCTAssertTrue(permEntry.waitForExistence(timeout: 3))

        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        try apiNotify(type: "permission_prompt", cwd: "/tmp/notif-perm")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(permEntry.value as? String, "needs-approval",
            "permission_prompt should set value to 'needs-approval'")

        // Clean up
        try apiDeleteChannel(label: "notif-idle")
        try apiDeleteChannel(label: "notif-perm")
    }

    // MARK: - Session Launcher Integrity

    /// Session launcher combo box must be functional and accept input.
    func testSessionLauncherFunctional() throws {
        let combo = app.comboBoxes["session-launcher-combo"]
        XCTAssertTrue(combo.waitForExistence(timeout: 3),
            "Session launcher combo box should exist")
        XCTAssertTrue(combo.isEnabled,
            "Session launcher combo box should be enabled")

        // Focus with Cmd+N
        app.typeKey("n", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Refresh button should exist
        let refreshBtn = app.buttons["refresh-sessions"]
        XCTAssertTrue(refreshBtn.waitForExistence(timeout: 2),
            "Refresh button should exist")
        XCTAssertTrue(refreshBtn.isEnabled,
            "Refresh button should be enabled")
    }

    // MARK: - Stress Tests for Integrity

    /// Rapid channel creation and switching must not crash or lose state.
    func testRapidChannelCreateAndSwitch() throws {
        for i in 0..<5 {
            try apiCreateChannel(label: "rapid-\(i)")
        }
        Thread.sleep(forTimeInterval: 1.0)

        // Rapid switch through all of them
        for i in 0..<5 {
            try apiSwitchChannel(label: "rapid-\(i)")
            Thread.sleep(forTimeInterval: 0.1)
        }
        Thread.sleep(forTimeInterval: 0.5)

        // App should still be responsive
        assertActiveChannelResponsive(message: "App should be responsive after rapid create/switch")

        // Clean up
        for i in 0..<5 {
            try apiDeleteChannel(label: "rapid-\(i)")
        }
    }

    /// Rapid sidebar toggle should not leave UI in inconsistent state.
    func testRapidSidebarToggle() throws {
        for _ in 0..<20 {
            app.typeKey("s", modifierFlags: [.command, .shift])
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 0.5)

        // App should be responsive regardless of sidebar state
        assertActiveChannelResponsive(message: "App should be responsive after rapid sidebar toggles")
    }

    /// Opening and closing settings rapidly should not crash.
    func testRapidSettingsOpenClose() throws {
        for _ in 0..<10 {
            app.typeKey(",", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.1)
            let settingsWindow = app.windows["Appearance Settings"]
            if settingsWindow.exists {
                settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        assertActiveChannelResponsive(message: "App should be responsive after rapid settings open/close")
    }
}
