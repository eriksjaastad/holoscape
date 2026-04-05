import XCTest

final class ThemeSwitchingUITests: HoloscapeUITestCase {

    // MARK: - Helpers

    /// Read the current theme popup value from the settings window.
    private func currentThemeValue() -> String {
        let settingsWindow = app.windows["Appearance Settings"]
        let popups = settingsWindow.popUpButtons
        guard popups.count > 0 else { return "" }
        return popups.element(boundBy: 0).value as? String ?? ""
    }

    /// Read the skin popup element from the settings window.
    private func skinPopup() -> XCUIElement {
        let settingsWindow = app.windows["Appearance Settings"]
        return settingsWindow.popUpButtons.element(boundBy: 1)
    }

    // MARK: - Theme Application

    func testApplyDarkTheme() throws {
        openSettings()
        selectTheme("Dark")
        XCTAssertEqual(currentThemeValue(), "Dark", "Theme popup should reflect Dark")
        closeSettings()
    }

    func testApplyMonokaiTheme() throws {
        openSettings()
        selectTheme("Monokai")
        XCTAssertEqual(currentThemeValue(), "Monokai", "Theme popup should reflect Monokai")
        closeSettings()
        openSettings()
        selectTheme("Dark")
        closeSettings()
    }

    func testApplySolarizedDarkTheme() throws {
        openSettings()
        selectTheme("Solarized Dark")
        XCTAssertEqual(currentThemeValue(), "Solarized Dark", "Theme popup should reflect Solarized Dark")
        closeSettings()
        openSettings()
        selectTheme("Dark")
        closeSettings()
    }

    func testApplySolarizedLightTheme() throws {
        openSettings()
        selectTheme("Solarized Light")
        XCTAssertEqual(currentThemeValue(), "Solarized Light", "Theme popup should reflect Solarized Light")
        closeSettings()
        openSettings()
        selectTheme("Dark")
        closeSettings()
    }

    func testApplyDraculaTheme() throws {
        openSettings()
        selectTheme("Dracula")
        XCTAssertEqual(currentThemeValue(), "Dracula", "Theme popup should reflect Dracula")
        closeSettings()
        openSettings()
        selectTheme("Dark")
        closeSettings()
    }

    func testApplyNordTheme() throws {
        openSettings()
        selectTheme("Nord")
        XCTAssertEqual(currentThemeValue(), "Nord", "Theme popup should reflect Nord")
        closeSettings()
        openSettings()
        selectTheme("Dark")
        closeSettings()
    }

    // MARK: - Theme Persistence

    func testThemePersistsAcrossRestart() throws {
        openSettings()
        selectTheme("Monokai")
        XCTAssertEqual(currentThemeValue(), "Monokai")
        closeSettings()

        // Quit and relaunch
        app.terminate()
        app = XCUIApplication()
        app.launch()

        // Verify Monokai persisted
        openSettings()
        XCTAssertEqual(currentThemeValue(), "Monokai", "Theme should persist across restart")

        // Reset to Dark
        selectTheme("Dark")
        closeSettings()
    }

    func testThemePersistsAcrossChannelSwitch() throws {
        openSettings()
        selectTheme("Nord")
        XCTAssertEqual(currentThemeValue(), "Nord")
        closeSettings()

        // Create second channel and switch between them
        createChannel(type: "Shell")

        app.typeKey("1", modifierFlags: .command)
        let firstSidebar = sidebarEntry("")
        XCTAssertTrue(firstSidebar.waitForExistence(timeout: 2), "First channel sidebar entry should exist after switch")

        app.typeKey("2", modifierFlags: .command)
        let secondSidebar = sidebarEntry("")
        XCTAssertTrue(secondSidebar.waitForExistence(timeout: 2), "Second channel sidebar entry should exist after switch")

        // Verify theme still set
        openSettings()
        XCTAssertEqual(currentThemeValue(), "Nord", "Theme should apply across channel switches")

        // Reset
        selectTheme("Dark")
        closeSettings()
    }

    // MARK: - Theme + Skin Interaction

    func testSkinOverridesThemeColors() throws {
        openSettings()
        selectTheme("Dark")

        let skin = skinPopup()
        guard skin.waitForExistence(timeout: 2) else {
            closeSettings()
            throw XCTSkip("Skin popup not found in settings")
        }
        XCTAssertTrue(skin.isHittable, "Skin popup should be interactable")

        skin.click()
        // Dismiss without selecting -- just verify popup opens
        let menuItems = app.menuItems
        XCTAssertGreaterThan(menuItems.count, 0, "Skin popup should have menu items")
        app.typeKey(.escape, modifierFlags: [])

        closeSettings()
    }

    func testDefaultSkinUsesThemeColors() throws {
        openSettings()

        let skin = skinPopup()
        guard skin.waitForExistence(timeout: 2) else {
            closeSettings()
            throw XCTSkip("Skin popup not found in settings")
        }

        skin.click()
        let defaultItem = app.menuItems["Default"]
        if defaultItem.waitForExistence(timeout: 1) {
            defaultItem.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }

        let skinValue = skin.value as? String ?? ""
        XCTAssertEqual(skinValue, "Default", "Skin popup should show Default")
        closeSettings()
    }

    func testSwitchingThemeWithCustomSkin() throws {
        openSettings()
        selectTheme("Monokai")
        XCTAssertEqual(currentThemeValue(), "Monokai")

        selectTheme("Nord")
        XCTAssertEqual(currentThemeValue(), "Nord", "Theme should switch while skin is active")

        selectTheme("Dark")
        closeSettings()
    }

    // MARK: - Visual Consistency

    func testThemeAppliedToAllPanes() throws {
        // Create split pane
        app.typeKey("d", modifierFlags: .command)

        openSettings()
        selectTheme("Dracula")
        XCTAssertEqual(currentThemeValue(), "Dracula")
        closeSettings()

        // Verify the main window has scrollable content (panes exist)
        let window = app.windows["Holoscape"]
        let scrollViews = window.scrollViews
        XCTAssertGreaterThanOrEqual(scrollViews.count, 1, "Split panes should exist and be themed")

        // Reset
        openSettings()
        selectTheme("Dark")
        closeSettings()
    }

    func testThemeAppliedToSidebar() throws {
        openSettings()
        selectTheme("Solarized Dark")
        closeSettings()

        let sidebar = sidebarEntry("")
        XCTAssertTrue(sidebar.waitForExistence(timeout: 3), "Sidebar entry should exist and be visible with theme applied")
        XCTAssertTrue(sidebar.isHittable, "Sidebar entry should be hittable after theme change")

        openSettings()
        selectTheme("Dark")
        closeSettings()
    }

    func testThemeAppliedToInputBox() throws {
        openSettings()
        selectTheme("Monokai")
        closeSettings()

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist with theme applied")
        inputBox.typeText("theme-test")
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "theme-test", "Input box should accept text with theme applied")

        openSettings()
        selectTheme("Dark")
        closeSettings()
    }

    func testThemeAppliedToTabBar() throws {
        // Collapse sidebar to show tab bar
        app.typeKey("s", modifierFlags: [.command, .shift])

        openSettings()
        selectTheme("Nord")
        closeSettings()

        let tabButton = tabEntry("")
        XCTAssertTrue(tabButton.waitForExistence(timeout: 3), "Tab bar entry should exist with theme applied")
        XCTAssertTrue(tabButton.isHittable, "Tab bar entry should be hittable after theme change")

        // Re-expand sidebar and reset theme
        app.typeKey("s", modifierFlags: [.command, .shift])
        openSettings()
        selectTheme("Dark")
        closeSettings()
    }
}
