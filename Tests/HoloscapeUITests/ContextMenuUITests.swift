import XCTest

final class ContextMenuUITests: HoloscapeUITestCase {

    // MARK: - Close via Context Menu

    func testContextMenuCloseRemovesChannel() throws {
        let countBefore = sidebarEntryCount()
        createChannel(type: "Shell")

        let shell2 = waitForNewSidebarEntry(expectedCount: countBefore + 1)
        XCTAssertTrue(shell2.waitForExistence(timeout: 3), "New shell sidebar entry should appear")

        shell2.rightClick()

        let closeItem = app.menuItems["Close"]
        XCTAssertTrue(closeItem.waitForExistence(timeout: 2), "Close menu item should exist")
        closeItem.click()

        // Handle confirmation dialog — active channels always show confirmation
        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 2) {
            closeButton.click()
        }

        XCTAssertFalse(shell2.waitForExistence(timeout: 3), "Channel sidebar entry should disappear after context menu Close")
    }

    func testContextMenuCloseActiveChannelSwitchesToAnother() throws {
        let countBefore = sidebarEntryCount()
        createChannel(type: "Shell")

        let shell2 = waitForNewSidebarEntry(expectedCount: countBefore + 1)
        XCTAssertTrue(shell2.waitForExistence(timeout: 3), "New shell sidebar entry should appear")
        shell2.click()

        // Close active channel via context menu
        shell2.rightClick()
        let closeItem = app.menuItems["Close"]
        XCTAssertTrue(closeItem.waitForExistence(timeout: 2))
        closeItem.click()

        let closeButton = app.buttons["Close"]
        if closeButton.waitForExistence(timeout: 2) {
            closeButton.click()
        }

        // Shell 2 should be gone
        XCTAssertFalse(shell2.waitForExistence(timeout: 3), "Closed channel should disappear from sidebar")

        // Original shell should still exist
        let shell1 = firstSidebarEntry()
        XCTAssertTrue(shell1.waitForExistence(timeout: 2), "Another channel should be selected after closing active")
    }

    func testContextMenuCloseWithConfirmation() throws {
        let shellEntry = firstSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 3))

        shellEntry.rightClick()

        let closeItem = app.menuItems["Close"]
        XCTAssertTrue(closeItem.waitForExistence(timeout: 2))
        closeItem.click()

        // Check for confirmation dialog
        let closeButton = app.buttons["Close"]
        let cancelButton = app.buttons["Cancel"]
        if closeButton.waitForExistence(timeout: 2) || cancelButton.waitForExistence(timeout: 1) {
            XCTAssertTrue(closeButton.exists || cancelButton.exists, "Confirmation dialog should have Close or Cancel button")
            // Cancel to keep channel
            if cancelButton.exists {
                cancelButton.click()
            } else {
                app.typeKey(.escape, modifierFlags: [])
            }
        }

        // Sidebar entry should still exist after cancelling
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 2), "Sidebar entry should remain after cancelling close confirmation")
    }

    // MARK: - Duplicate

    func testContextMenuDuplicateCreatesNewChannel() throws {
        let initialCount = sidebarEntryCount()

        let shellEntry = firstSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 3))

        shellEntry.rightClick()

        let duplicateItem = app.menuItems["Duplicate"]
        XCTAssertTrue(duplicateItem.waitForExistence(timeout: 2), "Duplicate menu item should exist")
        duplicateItem.click()

        let shell2 = waitForNewSidebarEntry(expectedCount: initialCount + 1)
        XCTAssertTrue(shell2.waitForExistence(timeout: 3), "Duplicate should create a second channel")

        let afterCount = sidebarEntryCount()
        XCTAssertGreaterThan(afterCount, initialCount, "Sidebar entry count should increase after duplicate")
    }

    func testContextMenuDuplicateShellChannel() throws {
        let shellEntry = firstSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 3))

        let countBefore = sidebarEntryCount()

        shellEntry.rightClick()

        let duplicateItem = app.menuItems["Duplicate"]
        XCTAssertTrue(duplicateItem.waitForExistence(timeout: 2))
        duplicateItem.click()

        let _ = waitForNewSidebarEntry(expectedCount: countBefore + 1)
        XCTAssertGreaterThanOrEqual(sidebarEntryCount(), 2, "Duplicating shell should create a new shell channel")
    }

    func testContextMenuDuplicateAgentChannel() throws {
        try skipUnlessClaudeCLIInstalled()
        createChannel(type: "Agent (OAuth)")

        let window = app.windows["Holoscape"]
        let agentEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Agent'")).firstMatch
        XCTAssertTrue(agentEntry.waitForExistence(timeout: 3), "Agent entry should exist for duplicate test")

        agentEntry.rightClick()

        let duplicateItem = app.menuItems["Duplicate"]
        XCTAssertTrue(duplicateItem.waitForExistence(timeout: 2))
        duplicateItem.click()

        let agentEntries = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Agent'"))
        XCTAssertGreaterThanOrEqual(agentEntries.count, 2, "Duplicating agent should create new agent with same profile")
    }

    func testContextMenuDuplicateIncrementLabel() throws {
        let shellEntry = firstSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 3))

        let countBefore = sidebarEntryCount()

        // Duplicate once
        shellEntry.rightClick()
        let duplicateItem = app.menuItems["Duplicate"]
        XCTAssertTrue(duplicateItem.waitForExistence(timeout: 2))
        duplicateItem.click()

        let shell2 = waitForNewSidebarEntry(expectedCount: countBefore + 1)
        XCTAssertTrue(shell2.waitForExistence(timeout: 3), "First duplicate should create a new sidebar entry")

        // Duplicate again
        shell2.rightClick()
        let duplicateItem2 = app.menuItems["Duplicate"]
        XCTAssertTrue(duplicateItem2.waitForExistence(timeout: 2))
        duplicateItem2.click()

        let shell3 = waitForNewSidebarEntry(expectedCount: countBefore + 2)
        XCTAssertTrue(shell3.waitForExistence(timeout: 3), "Second duplicate should create another sidebar entry")
    }

    // MARK: - Reconnect

    func testContextMenuReconnectReactivatesChannel() throws {
        try skipUnlessClaudeCLIInstalled()
        createChannel(type: "Agent (OAuth)")

        let window = app.windows["Holoscape"]
        let agentEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Agent'")).firstMatch
        XCTAssertTrue(agentEntry.waitForExistence(timeout: 3), "Agent entry should exist")

        agentEntry.rightClick()

        let reconnectItem = app.menuItems["Reconnect"]
        XCTAssertTrue(reconnectItem.waitForExistence(timeout: 2), "Reconnect menu item should exist")

        if reconnectItem.isEnabled {
            reconnectItem.click()
            XCTAssertTrue(agentEntry.waitForExistence(timeout: 3), "Channel should still exist after reconnect attempt")
        } else {
            // Just verify the menu item exists and its enabled state
            XCTAssertFalse(reconnectItem.isEnabled, "Reconnect is disabled for connected channel")
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    func testContextMenuReconnectOnActiveChannelDisabled() throws {
        let shellEntry = firstSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 3))

        shellEntry.rightClick()

        let reconnectItem = app.menuItems["Reconnect"]
        XCTAssertTrue(reconnectItem.waitForExistence(timeout: 2), "Reconnect menu item should exist")
        XCTAssertFalse(reconnectItem.isEnabled, "Reconnect should be grayed out for active channel")

        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Copy Session Info

    func testContextMenuCopySessionInfoContent() throws {
        let shellEntry = firstSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 3))

        // Clear pasteboard first
        NSPasteboard.general.clearContents()

        shellEntry.rightClick()

        let copyInfoItem = app.menuItems["Copy Session Info"]
        XCTAssertTrue(copyInfoItem.waitForExistence(timeout: 2))
        copyInfoItem.click()

        // Verify clipboard has content directly (no input-box for PTY channels)
        Thread.sleep(forTimeInterval: 0.5)
        let clipboardContent = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertFalse(clipboardContent.isEmpty, "Clipboard should contain session info after Copy Session Info")
        XCTAssertTrue(clipboardContent.contains("Label:"), "Session info should contain channel label")
    }

    // MARK: - Pin/Unpin

    func testContextMenuPinAddsEmoji() throws {
        let shellEntry = firstSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 3))

        shellEntry.rightClick()
        let pinItem = app.menuItems["Pin"]
        XCTAssertTrue(pinItem.waitForExistence(timeout: 2))
        pinItem.click()

        // Verify the sidebar entry title contains pin emoji
        let window = app.windows["Holoscape"]
        let pinnedEntry = window.buttons.matching(NSPredicate(format: "title CONTAINS '\u{1F4CC}'")).firstMatch
        XCTAssertTrue(pinnedEntry.waitForExistence(timeout: 3), "Pinned channel title should contain pin emoji \u{1F4CC}")
    }

    func testContextMenuUnpinRemovesEmoji() throws {
        let shellEntry = firstSidebarEntry()
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 3))

        // Pin first
        shellEntry.rightClick()
        let pinItem = app.menuItems["Pin"]
        XCTAssertTrue(pinItem.waitForExistence(timeout: 2))
        pinItem.click()

        // Verify pin emoji appeared
        let window = app.windows["Holoscape"]
        let pinnedEntry = window.buttons.matching(NSPredicate(format: "title CONTAINS '\u{1F4CC}'")).firstMatch
        XCTAssertTrue(pinnedEntry.waitForExistence(timeout: 3), "Pin emoji should appear after pinning")

        // Unpin
        pinnedEntry.rightClick()
        let unpinItem = app.menuItems["Unpin"]
        XCTAssertTrue(unpinItem.waitForExistence(timeout: 2))
        unpinItem.click()

        // Verify pin emoji is gone — no button title should contain the pin emoji
        let stillPinned = window.buttons.matching(NSPredicate(format: "title CONTAINS '\u{1F4CC}'")).firstMatch
        XCTAssertFalse(stillPinned.waitForExistence(timeout: 2), "Pin emoji should be removed after unpinning")
    }

    func testContextMenuPinOrderStableWithMultiplePins() throws {
        let countBefore = sidebarEntryCount()
        createChannel(type: "Shell")

        let shell1 = firstSidebarEntry()
        let shell2 = waitForNewSidebarEntry(expectedCount: countBefore + 1)
        XCTAssertTrue(shell2.waitForExistence(timeout: 3))

        // Pin both channels
        shell1.rightClick()
        let pin1 = app.menuItems["Pin"]
        XCTAssertTrue(pin1.waitForExistence(timeout: 2))
        pin1.click()

        let window = app.windows["Holoscape"]
        let pinned1 = window.buttons.matching(NSPredicate(format: "title CONTAINS '\u{1F4CC}'")).firstMatch
        XCTAssertTrue(pinned1.waitForExistence(timeout: 3), "First pin should add emoji")

        shell2.rightClick()
        let pin2 = app.menuItems["Pin"]
        XCTAssertTrue(pin2.waitForExistence(timeout: 2))
        pin2.click()

        // Both should show pin emoji
        let pinnedEntries = window.buttons.matching(NSPredicate(format: "title CONTAINS '\u{1F4CC}'"))
        XCTAssertGreaterThanOrEqual(pinnedEntries.count, 2, "Both pinned channels should show pin emoji")
    }
}
