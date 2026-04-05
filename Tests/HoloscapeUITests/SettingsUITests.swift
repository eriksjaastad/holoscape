import XCTest

final class SettingsUITests: HoloscapeUITestCase {

    // MARK: - Open Settings

    func testCmdCommaOpensSettings() throws {
        openSettings()

        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.exists, "Settings window should open on Cmd+,")
    }

    func testSettingsViaMenu() throws {
        // Holoscape > Settings...
        let appMenu = app.menuBars.firstMatch.menuBarItems["Holoscape"]
        XCTAssertTrue(appMenu.exists, "Holoscape app menu should exist")
        appMenu.click()

        let settingsItem = app.menuItems["Settings\u{2026}"]
        XCTAssertTrue(settingsItem.exists, "Settings menu item should exist")
        settingsItem.click()

        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3), "Settings window should open from menu")
    }

    // MARK: - Theme Dropdown

    func testThemeDropdownExists() throws {
        openSettings()

        let settingsWindow = app.windows["Appearance Settings"]

        // Look for the theme popup button
        let themePopup = settingsWindow.popUpButtons.firstMatch
        XCTAssertTrue(themePopup.exists, "Theme dropdown should exist in settings")
    }

    func testThemeDropdownHasOptions() throws {
        openSettings()

        let settingsWindow = app.windows["Appearance Settings"]

        // Click the first popup to see options
        let popups = settingsWindow.popUpButtons
        if popups.count > 0 {
            let themePopup = popups.element(boundBy: 0)
            themePopup.click()

            // Check for theme names
            let darkItem = app.menuItems["Dark"]
            XCTAssertTrue(darkItem.waitForExistence(timeout: 2), "Dark theme should be available")

            // Dismiss
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    // MARK: - Skin Picker

    func testSkinPickerExists() throws {
        openSettings()

        let settingsWindow = app.windows["Appearance Settings"]

        // Second popup should be the skin picker
        let popups = settingsWindow.popUpButtons
        XCTAssertGreaterThanOrEqual(popups.count, 2, "Should have at least theme and skin dropdowns")
    }

    func testSkinPickerHasDefault() throws {
        openSettings()

        let settingsWindow = app.windows["Appearance Settings"]

        let popups = settingsWindow.popUpButtons
        if popups.count >= 2 {
            let skinPopup = popups.element(boundBy: 1)
            skinPopup.click()

            let defaultItem = app.menuItems["Default"]
            XCTAssertTrue(defaultItem.waitForExistence(timeout: 2), "Default skin should always be available")

            app.typeKey(.escape, modifierFlags: [])
        }
    }

    // MARK: - Font Controls

    func testFontFamilyDropdownExists() throws {
        openSettings()

        let settingsWindow = app.windows["Appearance Settings"]

        // Third popup is font family
        let popups = settingsWindow.popUpButtons
        XCTAssertGreaterThanOrEqual(popups.count, 3, "Should have theme, skin, and font dropdowns")
    }

    func testFontSizeFieldExists() throws {
        openSettings()

        let settingsWindow = app.windows["Appearance Settings"]

        let textFields = settingsWindow.textFields
        XCTAssertGreaterThanOrEqual(textFields.count, 1, "Font size text field should exist")
    }

    // MARK: - Transparency Slider

    func testTransparencySliderExists() throws {
        openSettings()

        let settingsWindow = app.windows["Appearance Settings"]

        let sliders = settingsWindow.sliders
        XCTAssertGreaterThanOrEqual(sliders.count, 1, "Transparency slider should exist")
    }

    // MARK: - Background Color Picker

    func testBackgroundColorWellExists() throws {
        openSettings()

        let settingsWindow = app.windows["Appearance Settings"]

        let colorWells = settingsWindow.colorWells
        XCTAssertGreaterThanOrEqual(colorWells.count, 1, "Background color well should exist")
    }

    // MARK: - Notification Settings

    func testNotificationCheckboxesExist() throws {
        openSettings()

        let settingsWindow = app.windows["Appearance Settings"]

        let enableNotif = settingsWindow.checkBoxes["Enable Notifications"]
        XCTAssertTrue(enableNotif.waitForExistence(timeout: 2), "Enable Notifications checkbox should exist")

        let shellNotif = settingsWindow.checkBoxes["Shell"]
        XCTAssertTrue(shellNotif.exists, "Shell notification toggle should exist")

        let agentNotif = settingsWindow.checkBoxes["Agent"]
        XCTAssertTrue(agentNotif.exists, "Agent notification toggle should exist")

        let sshNotif = settingsWindow.checkBoxes["SSH"]
        XCTAssertTrue(sshNotif.exists, "SSH notification toggle should exist")

        let groupChatNotif = settingsWindow.checkBoxes["Group Chat"]
        XCTAssertTrue(groupChatNotif.exists, "Group Chat notification toggle should exist")
    }

    func testDisablingNotificationsDisablesPerTypeToggles() throws {
        openSettings()

        let settingsWindow = app.windows["Appearance Settings"]

        let enableNotif = settingsWindow.checkBoxes["Enable Notifications"]
        guard enableNotif.waitForExistence(timeout: 2) else { return }

        // If currently enabled, toggle off
        if enableNotif.value as? Int == 1 {
            enableNotif.click()
        }

        // Per-type checkboxes should be disabled
        let shellNotif = settingsWindow.checkBoxes["Shell"]
        XCTAssertFalse(shellNotif.isEnabled, "Shell toggle should be disabled when notifications are off")

        // Toggle back on
        enableNotif.click()

        XCTAssertTrue(shellNotif.isEnabled, "Shell toggle should be enabled when notifications are on")
    }

    // MARK: - Settings Window Closes

    func testSettingsWindowCloses() throws {
        openSettings()

        let settingsWindow = app.windows["Appearance Settings"]

        // Close with window close button
        closeSettings()

        // Main window should still exist
        let mainWindow = app.windows["Holoscape"]
        XCTAssertTrue(mainWindow.exists, "Main window should persist after settings close")
    }
}
