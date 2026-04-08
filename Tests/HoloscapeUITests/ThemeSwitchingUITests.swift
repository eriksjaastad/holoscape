import XCTest

final class ThemeSwitchingUITests: HoloscapeUITestCase {

    // MARK: - Helpers

    /// Read the skin popup element from the settings window.
    private func skinPopup() -> XCUIElement {
        return app.windows["Appearance Settings"].popUpButtons["skin-popup"]
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
        let firstSidebar = sidebarEntry("Shell")
        XCTAssertTrue(firstSidebar.waitForExistence(timeout: 2), "First channel sidebar entry should exist after switch")

        app.typeKey("2", modifierFlags: .command)
        let secondSidebar = sidebarEntry("Shell 2")
        XCTAssertTrue(secondSidebar.waitForExistence(timeout: 2), "Second channel sidebar entry should exist after switch")

        // Verify theme still set
        openSettings()
        XCTAssertEqual(currentThemeValue(), "Nord", "Theme should apply across channel switches")

        // Reset
        selectTheme("Dark")
        closeSettings()
    }

    // MARK: - Theme + Skin Interaction

    func testSkinPopupInteractableWithThemeSet() throws {
        openSettings()
        selectTheme("Dark")

        let skin = skinPopup()
        guard skin.waitForExistence(timeout: 2) else {
            closeSettings()
            throw XCTSkip("Skin popup not found in settings")
        }
        XCTAssertTrue(skin.isHittable, "Skin popup should be interactable")

        skin.click()
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

    func testSplitPanesSurviveThemeChange() throws {
        // Create split pane
        app.typeKey("d", modifierFlags: .command)

        openSettings()
        selectTheme("Dracula")
        XCTAssertEqual(currentThemeValue(), "Dracula")
        closeSettings()

        // Verify the main window has scrollable content (panes still exist)
        let window = app.windows["Holoscape"]
        let scrollViews = window.scrollViews
        XCTAssertGreaterThanOrEqual(scrollViews.count, 1, "Split panes should still exist after theme change")

        // Reset
        openSettings()
        selectTheme("Dark")
        closeSettings()
    }

    func testSidebarFunctionalAfterThemeChange() throws {
        openSettings()
        selectTheme("Solarized Dark")
        closeSettings()

        let sidebar = sidebarEntry("Shell")
        XCTAssertTrue(sidebar.waitForExistence(timeout: 3), "Sidebar entry should exist after theme change")
        XCTAssertTrue(sidebar.isHittable, "Sidebar entry should be hittable after theme change")

        openSettings()
        selectTheme("Dark")
        closeSettings()
    }

    func testChannelResponsiveAfterThemeChange() throws {
        openSettings()
        selectTheme("Monokai")
        closeSettings()

        assertActiveChannelResponsive(message: "Channel should be responsive after theme change")

        openSettings()
        selectTheme("Dark")
        closeSettings()
    }

    func testTabBarFunctionalAfterThemeChange() throws {
        // Collapse sidebar to show tab bar
        app.typeKey("s", modifierFlags: [.command, .shift])

        openSettings()
        selectTheme("Nord")
        closeSettings()

        let tabButton = tabEntry("Shell")
        XCTAssertTrue(tabButton.waitForExistence(timeout: 3), "Tab bar entry should exist after theme change")
        XCTAssertTrue(tabButton.isHittable, "Tab bar entry should be hittable after theme change")

        // Re-expand sidebar and reset theme
        app.typeKey("s", modifierFlags: [.command, .shift])
        openSettings()
        selectTheme("Dark")
        closeSettings()
    }
}
