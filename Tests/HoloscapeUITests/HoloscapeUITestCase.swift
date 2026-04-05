import XCTest

/// Shared base class for all Holoscape UI tests.
/// Provides common setup/teardown, channel creation helpers, and settings helpers.
class HoloscapeUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Channel Helpers

    /// Create a channel via File > New Channel dialog.
    /// Valid types: "Shell", "Agent (OAuth)", "Agent (API Key)", "Group Chat", "Bridge"
    func createChannel(type: String) {
        app.menuBars.firstMatch.menuBarItems["File"].click()
        let newChannelItem = app.menuItems["New Channel"]
        XCTAssertTrue(newChannelItem.waitForExistence(timeout: 2), "New Channel menu item should exist")
        newChannelItem.click()
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 3), "New Channel dialog should appear")
        let button = dialog.buttons[type]
        XCTAssertTrue(button.waitForExistence(timeout: 2), "\(type) button should exist in dialog")
        button.click()
    }

    /// Find a sidebar entry by partial identifier match (CONTAINS).
    func sidebarEntry(_ label: String) -> XCUIElement {
        let window = app.windows["Holoscape"]
        return window.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "sidebar-\(label)")).firstMatch
    }

    /// Find a sidebar entry by exact identifier match.
    func sidebarEntryExact(_ label: String) -> XCUIElement {
        let window = app.windows["Holoscape"]
        return window.buttons.matching(NSPredicate(format: "identifier == %@", "sidebar-\(label)")).firstMatch
    }

    /// Find a pinned sidebar entry by label. Queries accessibility title for pin emoji.
    func pinnedSidebarEntry(_ label: String) -> XCUIElement {
        let window = app.windows["Holoscape"]
        return window.buttons.matching(NSPredicate(
            format: "title CONTAINS %@ AND title CONTAINS %@",
            "\u{1F4CC}", label
        )).firstMatch
    }

    /// Count sidebar entries.
    func sidebarEntryCount() -> Int {
        let window = app.windows["Holoscape"]
        return window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'")).count
    }

    /// Find a tab bar entry by partial identifier match.
    func tabEntry(_ identifier: String) -> XCUIElement {
        let window = app.windows["Holoscape"]
        return window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tab-\(identifier)")).firstMatch
    }

    // MARK: - Settings Helpers

    func openSettings() {
        app.typeKey(",", modifierFlags: .command)
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3), "Settings window should open")
    }

    func closeSettings() {
        let settingsWindow = app.windows["Appearance Settings"]
        if settingsWindow.exists {
            settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
        }
    }

    /// Get the settings window's theme popup by accessibility identifier.
    func themePopup() -> XCUIElement {
        return app.windows["Appearance Settings"].popUpButtons["theme-popup"]
    }

    /// Get the settings window's font family popup by accessibility identifier.
    func fontFamilyPopup() -> XCUIElement {
        return app.windows["Appearance Settings"].popUpButtons["font-family-popup"]
    }

    /// Get the settings window's font size field by accessibility identifier.
    func fontSizeField() -> XCUIElement {
        return app.windows["Appearance Settings"].textFields["font-size-field"]
    }

    /// Get the settings window's transparency slider by accessibility identifier.
    func transparencySlider() -> XCUIElement {
        return app.windows["Appearance Settings"].sliders["transparency-slider"]
    }

    /// Select a theme from the settings theme popup.
    func selectTheme(_ name: String) {
        let popup = themePopup()
        guard popup.waitForExistence(timeout: 2) else {
            XCTFail("Theme popup not found — cannot select '\(name)'")
            return
        }
        popup.click()
        let themeItem = app.menuItems[name]
        if themeItem.waitForExistence(timeout: 1) {
            themeItem.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
            XCTFail("Theme '\(name)' not found in theme popup")
        }
    }

    /// Select a font from the settings font family popup.
    func selectFont(_ name: String) {
        let popup = fontFamilyPopup()
        guard popup.waitForExistence(timeout: 2) else {
            XCTFail("Font popup not found — cannot select '\(name)'")
            return
        }
        popup.click()
        let fontItem = app.menuItems[name]
        if fontItem.waitForExistence(timeout: 1) {
            fontItem.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
            XCTFail("Font '\(name)' not found in font popup — may not be installed")
        }
    }

    /// Set font size in the settings text field.
    func setFontSize(_ size: String) {
        let field = fontSizeField()
        guard field.waitForExistence(timeout: 2) else {
            XCTFail("Font size field not found in settings")
            return
        }
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(size)
        field.typeKey(.return, modifierFlags: [])
    }

    /// Read current theme popup value.
    func currentThemeValue() -> String {
        let popup = themePopup()
        guard popup.waitForExistence(timeout: 2) else {
            XCTFail("Theme popup not found")
            return ""
        }
        return popup.value as? String ?? ""
    }

    /// Read current font family popup value.
    func currentFontValue() -> String {
        let popup = fontFamilyPopup()
        guard popup.waitForExistence(timeout: 2) else {
            XCTFail("Font popup not found")
            return ""
        }
        return popup.value as? String ?? ""
    }

    /// Read current font size field value.
    func currentFontSizeValue() -> String {
        let field = fontSizeField()
        guard field.waitForExistence(timeout: 2) else {
            XCTFail("Font size field not found")
            return ""
        }
        return field.value as? String ?? ""
    }

    // MARK: - Search Helpers

    func openSearch() {
        app.typeKey("f", modifierFlags: .command)
        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2), "Search bar should open")
    }

    func closeSearch() {
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Read the match count label text from the search bar.
    func searchMatchCountText() -> String? {
        let searchBar = app.toolbars["Search Bar"]
        let label = searchBar.staticTexts["search-match-count"]
        if label.exists {
            return label.label
        }
        return nil
    }

    // MARK: - Dependency Checks

    /// Skip test if the Claude CLI binary is not installed.
    func skipUnlessClaudeCLIInstalled() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: "/opt/homebrew/bin/claude"),
            "Claude CLI not installed at /opt/homebrew/bin/claude"
        )
    }

    /// Skip test if a font family is not available on this system.
    func skipUnlessFontAvailable(_ fontName: String) throws {
        let available = NSFontManager.shared.availableFontFamilies.contains(fontName)
        try XCTSkipUnless(available, "Font '\(fontName)' not installed on this system")
    }
}
