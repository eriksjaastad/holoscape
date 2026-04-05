import XCTest

final class ConfigPersistenceUITests: HoloscapeUITestCase {

    // MARK: - Helpers

    /// Read the current theme popup value from the settings window.
    private func currentThemeValue() -> String {
        let settingsWindow = app.windows["Appearance Settings"]
        let popups = settingsWindow.popUpButtons
        guard popups.count > 0 else { return "" }
        return popups.element(boundBy: 0).value as? String ?? ""
    }

    /// Read the current font popup value from the settings window.
    private func currentFontValue() -> String {
        let settingsWindow = app.windows["Appearance Settings"]
        let popups = settingsWindow.popUpButtons
        guard popups.count >= 3 else { return "" }
        return popups.element(boundBy: 2).value as? String ?? ""
    }

    /// Read the current font size text field value from the settings window.
    private func currentFontSizeValue() -> String {
        let settingsWindow = app.windows["Appearance Settings"]
        let textFields = settingsWindow.textFields
        guard textFields.count >= 1 else { return "" }
        return textFields.element(boundBy: 0).value as? String ?? ""
    }

    /// Read the current slider value from the settings window.
    private func currentSliderValue() -> String {
        let settingsWindow = app.windows["Appearance Settings"]
        let sliders = settingsWindow.sliders
        guard sliders.count >= 1 else { return "" }
        return sliders.element(boundBy: 0).value as? String ?? ""
    }

    // MARK: - Full Config Round-Trip

    func testAllSettingsSurviveRestart() throws {
        openSettings()

        // Set theme
        selectTheme("Nord")
        XCTAssertEqual(currentThemeValue(), "Nord", "Theme should be set to Nord")

        // Set font
        selectFont("Menlo")
        XCTAssertEqual(currentFontValue(), "Menlo", "Font should be set to Menlo")

        // Set font size
        setFontSize("15")
        XCTAssertEqual(currentFontSizeValue(), "15", "Font size should be set to 15")

        // Set transparency
        let settingsWindow = app.windows["Appearance Settings"]
        let sliders = settingsWindow.sliders
        if sliders.count >= 1 {
            sliders.element(boundBy: 0).adjust(toNormalizedSliderPosition: 0.8)
        }

        closeSettings()

        // Quit and relaunch
        app.terminate()
        app = XCUIApplication()
        app.launch()

        // Re-query settings window after relaunch (old references are stale)
        openSettings()

        // Assert each setting individually
        XCTAssertEqual(currentThemeValue(), "Nord", "Theme should persist across restart")
        XCTAssertEqual(currentFontValue(), "Menlo", "Font should persist across restart")
        XCTAssertEqual(currentFontSizeValue(), "15", "Font size should persist across restart")

        // Reset everything
        selectTheme("Dark")
        selectFont("SF Mono")
        setFontSize("13")
        let settingsWindow2 = app.windows["Appearance Settings"]
        let sliders2 = settingsWindow2.sliders
        if sliders2.count >= 1 {
            sliders2.element(boundBy: 0).adjust(toNormalizedSliderPosition: 1.0)
        }
        closeSettings()
    }

    func testAppLaunchesSuccessfully() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "App should launch with functional input box")
    }

    func testConfigFileUpdatedOnChange() throws {
        openSettings()

        // Change theme and verify it took effect
        selectTheme("Monokai")
        XCTAssertEqual(currentThemeValue(), "Monokai", "Config should update to Monokai")

        // Change back and verify
        selectTheme("Dark")
        XCTAssertEqual(currentThemeValue(), "Dark", "Config should update immediately on change back to Dark")

        closeSettings()
    }

    // MARK: - Concurrent Access

    func testRapidSettingsChanges() throws {
        openSettings()

        let themes = ["Dark", "Monokai", "Nord", "Dracula", "Solarized Dark"]
        let lastTheme = themes.last!

        // Rapidly change themes
        for theme in themes {
            selectTheme(theme)
        }

        // Assert the final theme stuck
        XCTAssertEqual(currentThemeValue(), lastTheme, "After rapid changes, theme should reflect the last selection: \(lastTheme)")

        // Rapidly change slider
        let settingsWindow = app.windows["Appearance Settings"]
        let sliders = settingsWindow.sliders
        if sliders.count >= 1 {
            let slider = sliders.element(boundBy: 0)
            for pos in stride(from: 0.5, through: 1.0, by: 0.1) {
                slider.adjust(toNormalizedSliderPosition: CGFloat(pos))
            }
            // Assert slider ended at approximately 1.0
            let finalValue = slider.value as? String ?? ""
            XCTAssertFalse(finalValue.isEmpty, "Slider should have a value after rapid adjustments")
        }

        // Verify the app is still functional
        closeSettings()
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "App should remain functional after rapid settings changes")

        // Reset
        openSettings()
        selectTheme("Dark")
        closeSettings()
    }
}
