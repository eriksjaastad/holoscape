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
    func sidebarEntry(_ identifier: String) -> XCUIElement {
        let window = app.windows["Holoscape"]
        return window.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "sidebar-\(identifier)")).firstMatch
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
        guard popups.count > 0 else { return }
        let themePopup = popups.element(boundBy: 0)
        themePopup.click()
        let themeItem = app.menuItems[name]
        if themeItem.waitForExistence(timeout: 1) {
            themeItem.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    /// Select a font from the settings font popup (index 2).
    func selectFont(_ name: String) {
        let settingsWindow = app.windows["Appearance Settings"]
        let popups = settingsWindow.popUpButtons
        guard popups.count >= 3 else { return }
        let fontPopup = popups.element(boundBy: 2)
        fontPopup.click()
        let fontItem = app.menuItems[name]
        if fontItem.waitForExistence(timeout: 1) {
            fontItem.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    /// Set font size in the settings text field (index 0).
    func setFontSize(_ size: String) {
        let settingsWindow = app.windows["Appearance Settings"]
        let textFields = settingsWindow.textFields
        guard textFields.count >= 1 else { return }
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

    // MARK: - Dependency Checks

    /// Skip test if the Claude CLI binary is not installed.
    func skipUnlessClaudeCLIInstalled() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: "/opt/homebrew/bin/claude"),
            "Claude CLI not installed at /opt/homebrew/bin/claude"
        )
    }
}
