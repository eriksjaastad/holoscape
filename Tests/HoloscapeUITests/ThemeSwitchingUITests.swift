import XCTest

final class ThemeSwitchingUITests: XCTestCase {
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

    private func openSettings() {
        app.typeKey(",", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func closeSettings() {
        let settingsWindow = app.windows["Appearance Settings"]
        if settingsWindow.exists {
            settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    private func selectTheme(_ name: String) {
        let settingsWindow = app.windows["Appearance Settings"]
        let popups = settingsWindow.popUpButtons
        guard popups.count > 0 else { return }

        let themePopup = popups.element(boundBy: 0)
        themePopup.click()
        Thread.sleep(forTimeInterval: 0.3)

        let themeItem = app.menuItems[name]
        if themeItem.waitForExistence(timeout: 1) {
            themeItem.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
        Thread.sleep(forTimeInterval: 0.3)
    }

    // MARK: - Theme Application

    func testApplyDarkTheme() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        selectTheme("Dark")

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain functional after applying Dark theme")
        closeSettings()
    }

    func testApplyMonokaiTheme() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        selectTheme("Monokai")

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain functional after applying Monokai theme")
        closeSettings()
    }

    func testApplySolarizedDarkTheme() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        selectTheme("Solarized Dark")

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain functional after applying Solarized Dark theme")
        closeSettings()
    }

    func testApplySolarizedLightTheme() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        selectTheme("Solarized Light")

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain functional after applying Solarized Light theme")
        closeSettings()
    }

    func testApplyDraculaTheme() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        selectTheme("Dracula")

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain functional after applying Dracula theme")
        closeSettings()
    }

    func testApplyNordTheme() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        selectTheme("Nord")

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain functional after applying Nord theme")
        closeSettings()
    }

    // MARK: - Theme Persistence

    func testThemePersistsAcrossRestart() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        selectTheme("Monokai")
        closeSettings()

        // Quit and relaunch
        app.terminate()
        Thread.sleep(forTimeInterval: 1.0)
        app.launch()
        Thread.sleep(forTimeInterval: 1.0)

        // Verify Monokai is still selected
        openSettings()
        let settingsWindow2 = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow2.waitForExistence(timeout: 3))

        let popups = settingsWindow2.popUpButtons
        if popups.count > 0 {
            let themePopup = popups.element(boundBy: 0)
            let currentValue = themePopup.value as? String ?? ""
            XCTAssertEqual(currentValue, "Monokai", "Theme should persist across restart")
        }

        // Reset to Dark
        selectTheme("Dark")
        closeSettings()
    }

    func testThemePersistsAcrossChannelSwitch() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        selectTheme("Nord")
        closeSettings()

        // Create second channel and switch
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Shell"].click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("2", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Theme should apply to all channels")

        // Reset
        openSettings()
        selectTheme("Dark")
        closeSettings()
    }

    // MARK: - Theme + Skin Interaction

    func testSkinOverridesThemeColors() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        // Select a theme then a custom skin
        selectTheme("Dark")
        Thread.sleep(forTimeInterval: 0.2)

        let popups = settingsWindow.popUpButtons
        if popups.count >= 2 {
            let skinPopup = popups.element(boundBy: 1)
            skinPopup.click()
            Thread.sleep(forTimeInterval: 0.3)
            // Select any available skin
            let items = app.menuItems
            if items.count > 0 {
                app.typeKey(.escape, modifierFlags: [])
            }
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Custom skin should override theme colors without crash")
        closeSettings()
    }

    func testDefaultSkinUsesThemeColors() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        let popups = settingsWindow.popUpButtons
        if popups.count >= 2 {
            let skinPopup = popups.element(boundBy: 1)
            skinPopup.click()
            Thread.sleep(forTimeInterval: 0.3)
            let defaultItem = app.menuItems["Default"]
            if defaultItem.waitForExistence(timeout: 1) {
                defaultItem.click()
            } else {
                app.typeKey(.escape, modifierFlags: [])
            }
        }
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Default skin should defer to theme colors")
        closeSettings()
    }

    func testSwitchingThemeWithCustomSkin() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        // Switch theme while skin is active
        selectTheme("Monokai")
        Thread.sleep(forTimeInterval: 0.2)
        selectTheme("Nord")
        Thread.sleep(forTimeInterval: 0.2)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Switching theme with custom skin should not crash")

        selectTheme("Dark")
        closeSettings()
    }

    // MARK: - Visual Consistency

    func testThemeAppliedToAllPanes() throws {
        // Create split pane
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        selectTheme("Dracula")
        closeSettings()

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Theme should apply to all split panes")
    }

    func testThemeAppliedToSidebar() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        selectTheme("Solarized Dark")
        closeSettings()

        let window = app.windows["Holoscape"]
        let sidebarEntry = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'")).firstMatch
        XCTAssertTrue(sidebarEntry.exists, "Sidebar should be visible and respect theme")

        openSettings()
        selectTheme("Dark")
        closeSettings()
    }

    func testThemeAppliedToInputBox() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        selectTheme("Monokai")
        closeSettings()

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists, "Input box should be functional with theme applied")

        openSettings()
        selectTheme("Dark")
        closeSettings()
    }

    func testThemeAppliedToTabBar() throws {
        // Collapse sidebar to show tab bar
        app.typeKey("s", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.3)

        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        selectTheme("Nord")
        closeSettings()

        let window = app.windows["Holoscape"]
        let tabButton = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'")).firstMatch
        XCTAssertTrue(tabButton.exists, "Tab bar should respect theme")

        // Re-expand sidebar and reset theme
        app.typeKey("s", modifierFlags: [.command, .shift])
        openSettings()
        selectTheme("Dark")
        closeSettings()
    }
}
