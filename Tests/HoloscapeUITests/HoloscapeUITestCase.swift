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

    /// Find a sidebar entry by partial identifier match.
    func sidebarEntry(_ label: String) -> XCUIElement {
        let window = app.windows["Holoscape"]
        return window.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "sidebar-\(label)")).firstMatch
    }

    /// Find a sidebar entry by exact identifier match.
    func sidebarEntryExact(_ label: String) -> XCUIElement {
        let window = app.windows["Holoscape"]
        return window.buttons.matching(NSPredicate(format: "identifier == %@", "sidebar-\(label)")).firstMatch
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

    /// Select a theme from the settings theme popup (index 0).
    func selectTheme(_ name: String) {
        let settingsWindow = app.windows["Appearance Settings"]
        let popups = settingsWindow.popUpButtons
        guard popups.count > 0 else {
            XCTFail("No popup buttons found in settings — cannot select theme '\(name)'")
            return
        }
        let themePopup = popups.element(boundBy: 0)
        themePopup.click()
        let themeItem = app.menuItems[name]
        if themeItem.waitForExistence(timeout: 1) {
            themeItem.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
            XCTFail("Theme '\(name)' not found in theme popup")
        }
    }

    /// Select a font from the settings font popup (index 2).
    func selectFont(_ name: String) {
        let settingsWindow = app.windows["Appearance Settings"]
        let popups = settingsWindow.popUpButtons
        guard popups.count >= 3 else {
            XCTFail("Font popup not found in settings — need at least 3 popups, found \(popups.count)")
            return
        }
        let fontPopup = popups.element(boundBy: 2)
        fontPopup.click()
        let fontItem = app.menuItems[name]
        if fontItem.waitForExistence(timeout: 1) {
            fontItem.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
            XCTFail("Font '\(name)' not found in font popup — may not be installed")
        }
    }

    /// Set font size in the settings text field (index 0).
    func setFontSize(_ size: String) {
        let settingsWindow = app.windows["Appearance Settings"]
        let textFields = settingsWindow.textFields
        guard textFields.count >= 1 else {
            XCTFail("Font size text field not found in settings")
            return
        }
        let sizeField = textFields.element(boundBy: 0)
        sizeField.click()
        sizeField.typeKey("a", modifierFlags: .command)
        sizeField.typeText(size)
        sizeField.typeKey(.return, modifierFlags: [])
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
