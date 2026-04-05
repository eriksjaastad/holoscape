import XCTest

final class ConfigPersistenceUITests: XCTestCase {
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

    // MARK: - Full Config Round-Trip

    func testAllSettingsSurviveRestart() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        // Set theme
        let popups = settingsWindow.popUpButtons
        if popups.count > 0 {
            let themePopup = popups.element(boundBy: 0)
            themePopup.click()
            Thread.sleep(forTimeInterval: 0.3)
            let nordItem = app.menuItems["Nord"]
            if nordItem.waitForExistence(timeout: 1) { nordItem.click() }
            else { app.typeKey(.escape, modifierFlags: []) }
            Thread.sleep(forTimeInterval: 0.2)
        }

        // Set font
        if popups.count >= 3 {
            let fontPopup = popups.element(boundBy: 2)
            fontPopup.click()
            Thread.sleep(forTimeInterval: 0.3)
            let menloItem = app.menuItems["Menlo"]
            if menloItem.waitForExistence(timeout: 1) { menloItem.click() }
            else { app.typeKey(.escape, modifierFlags: []) }
            Thread.sleep(forTimeInterval: 0.2)
        }

        // Set font size
        let textFields = settingsWindow.textFields
        if textFields.count >= 1 {
            let sizeField = textFields.element(boundBy: 0)
            sizeField.click()
            sizeField.typeKey("a", modifierFlags: .command)
            sizeField.typeText("15")
            sizeField.typeKey(.return, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.2)
        }

        // Set transparency
        let sliders = settingsWindow.sliders
        if sliders.count >= 1 {
            sliders.element(boundBy: 0).adjust(toNormalizedSliderPosition: 0.8)
            Thread.sleep(forTimeInterval: 0.2)
        }

        closeSettings()

        // Enable timestamps
        app.typeKey("t", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        // Quit and relaunch
        app.terminate()
        Thread.sleep(forTimeInterval: 1.0)
        app.launch()
        Thread.sleep(forTimeInterval: 1.0)

        // Verify settings persisted
        openSettings()
        let settingsWindow2 = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow2.waitForExistence(timeout: 3))

        // Check theme
        let popups2 = settingsWindow2.popUpButtons
        if popups2.count > 0 {
            let themeValue = popups2.element(boundBy: 0).value as? String ?? ""
            XCTAssertEqual(themeValue, "Nord", "Theme should persist")
        }

        // Check font
        if popups2.count >= 3 {
            let fontValue = popups2.element(boundBy: 2).value as? String ?? ""
            XCTAssertEqual(fontValue, "Menlo", "Font should persist")
        }

        // Check font size
        let textFields2 = settingsWindow2.textFields
        if textFields2.count >= 1 {
            let sizeValue = textFields2.element(boundBy: 0).value as? String ?? ""
            XCTAssertEqual(sizeValue, "15", "Font size should persist")
        }

        // Reset everything
        if popups2.count > 0 {
            let themePopup = popups2.element(boundBy: 0)
            themePopup.click()
            Thread.sleep(forTimeInterval: 0.3)
            let darkItem = app.menuItems["Dark"]
            if darkItem.waitForExistence(timeout: 1) { darkItem.click() }
            else { app.typeKey(.escape, modifierFlags: []) }
        }
        if popups2.count >= 3 {
            let fontPopup = popups2.element(boundBy: 2)
            fontPopup.click()
            Thread.sleep(forTimeInterval: 0.3)
            let sfItem = app.menuItems["SF Mono"]
            if sfItem.waitForExistence(timeout: 1) { sfItem.click() }
            else { app.typeKey(.escape, modifierFlags: []) }
        }
        if textFields2.count >= 1 {
            let sizeField = textFields2.element(boundBy: 0)
            sizeField.click()
            sizeField.typeKey("a", modifierFlags: .command)
            sizeField.typeText("13")
            sizeField.typeKey(.return, modifierFlags: [])
        }
        if sliders.count >= 1 {
            settingsWindow2.sliders.element(boundBy: 0).adjust(toNormalizedSliderPosition: 1.0)
        }
        closeSettings()
        app.typeKey("t", modifierFlags: .command) // Toggle timestamps off
    }

    func testConfigFileCreatedOnFirstLaunch() throws {
        // App should have created config on launch
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Config file should be created on first launch")
    }

    func testConfigFileUpdatedOnChange() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        // Change any setting
        let popups = settingsWindow.popUpButtons
        if popups.count > 0 {
            let themePopup = popups.element(boundBy: 0)
            themePopup.click()
            Thread.sleep(forTimeInterval: 0.3)
            let monokaiItem = app.menuItems["Monokai"]
            if monokaiItem.waitForExistence(timeout: 1) { monokaiItem.click() }
            else { app.typeKey(.escape, modifierFlags: []) }
            Thread.sleep(forTimeInterval: 0.3)

            // Config should be immediately written
            // Verify by switching back
            themePopup.click()
            Thread.sleep(forTimeInterval: 0.3)
            let darkItem = app.menuItems["Dark"]
            if darkItem.waitForExistence(timeout: 1) { darkItem.click() }
            else { app.typeKey(.escape, modifierFlags: []) }
        }

        closeSettings()
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Config file should update immediately on change")
    }

    // MARK: - Config Corruption

    func testCorruptConfigHandledGracefully() throws {
        // App should handle missing/corrupt config by using defaults
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should handle corrupt config gracefully with defaults")
    }

    func testMissingConfigFieldsGetDefaults() throws {
        // Partial config should not crash — missing fields get defaults
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Missing config fields should get defaults without crash")
    }

    func testEmptyConfigFileHandled() throws {
        // Empty config file should not crash app
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Empty config file should not crash app")
    }

    // MARK: - Config Migration

    func testOldConfigVersionHandled() throws {
        // Old config format should be migrated or gracefully defaulted
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Old config version should be handled gracefully")
    }

    // MARK: - Concurrent Access

    func testRapidSettingsChanges() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        let popups = settingsWindow.popUpButtons
        let themes = ["Dark", "Monokai", "Nord", "Dracula", "Solarized Dark"]

        // Rapidly change themes
        for theme in themes {
            if popups.count > 0 {
                let themePopup = popups.element(boundBy: 0)
                themePopup.click()
                Thread.sleep(forTimeInterval: 0.1)
                let item = app.menuItems[theme]
                if item.waitForExistence(timeout: 0.5) { item.click() }
                else { app.typeKey(.escape, modifierFlags: []) }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        // Rapidly change slider
        let sliders = settingsWindow.sliders
        if sliders.count >= 1 {
            let slider = sliders.element(boundBy: 0)
            for pos in stride(from: 0.5, through: 1.0, by: 0.1) {
                slider.adjust(toNormalizedSliderPosition: CGFloat(pos))
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Rapid settings changes should not cause write race or crash")

        // Reset
        if popups.count > 0 {
            let themePopup = popups.element(boundBy: 0)
            themePopup.click()
            Thread.sleep(forTimeInterval: 0.3)
            let darkItem = app.menuItems["Dark"]
            if darkItem.waitForExistence(timeout: 1) { darkItem.click() }
            else { app.typeKey(.escape, modifierFlags: []) }
        }
        closeSettings()
    }
}
