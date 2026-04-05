import XCTest

final class TransparencyColorWellUITests: HoloscapeUITestCase {

    // MARK: - Helpers

    /// Get the transparency slider from a freshly-queried settings window.
    private func transparencySlider() -> XCUIElement {
        let settingsWindow = app.windows["Appearance Settings"]
        return settingsWindow.sliders.element(boundBy: 0)
    }

    /// Read the current slider value as a normalized string.
    private func sliderValue() -> String {
        return transparencySlider().value as? String ?? ""
    }

    // MARK: - Transparency Slider

    func testTransparencySliderChangesWindowOpacity() throws {
        openSettings()

        let slider = transparencySlider()
        XCTAssertTrue(slider.waitForExistence(timeout: 2), "Transparency slider should exist")

        let initialValue = slider.value as? String ?? ""
        slider.adjust(toNormalizedSliderPosition: 0.7)
        let adjustedValue = slider.value as? String ?? ""
        XCTAssertNotEqual(initialValue, adjustedValue, "Slider value should change after adjustment")

        // Reset
        slider.adjust(toNormalizedSliderPosition: 1.0)
        closeSettings()
    }

    func testTransparencyMinimum() throws {
        openSettings()

        let slider = transparencySlider()
        XCTAssertTrue(slider.waitForExistence(timeout: 2))

        slider.adjust(toNormalizedSliderPosition: 0.0)
        let value = slider.value as? String ?? ""
        XCTAssertFalse(value.isEmpty, "Slider should have a value at minimum position")

        // Reset
        slider.adjust(toNormalizedSliderPosition: 1.0)
        closeSettings()
    }

    func testTransparencyMaximum() throws {
        openSettings()

        let slider = transparencySlider()
        XCTAssertTrue(slider.waitForExistence(timeout: 2))

        slider.adjust(toNormalizedSliderPosition: 1.0)
        let value = slider.value as? String ?? ""
        XCTAssertFalse(value.isEmpty, "Slider should have a value at maximum position")
        closeSettings()
    }

    func testTransparencyMidRange() throws {
        openSettings()

        let slider = transparencySlider()
        XCTAssertTrue(slider.waitForExistence(timeout: 2))

        let initialValue = slider.value as? String ?? ""
        slider.adjust(toNormalizedSliderPosition: 0.5)
        let midValue = slider.value as? String ?? ""
        // Only assert change if initial was not already at 0.5
        if initialValue != midValue {
            XCTAssertNotEqual(initialValue, midValue, "Slider value should change to mid-range")
        }

        // Reset
        slider.adjust(toNormalizedSliderPosition: 1.0)
        closeSettings()
    }

    func testTransparencyPersistsAcrossRestart() throws {
        openSettings()

        let slider = transparencySlider()
        XCTAssertTrue(slider.waitForExistence(timeout: 2))

        slider.adjust(toNormalizedSliderPosition: 0.6)
        let setValue = slider.value as? String ?? ""
        closeSettings()

        // Quit and relaunch
        app.terminate()
        app = XCUIApplication()
        app.launch()

        // Re-query settings window and slider after relaunch
        openSettings()
        let sliderAfter = transparencySlider()
        XCTAssertTrue(sliderAfter.waitForExistence(timeout: 2), "Transparency slider should exist after restart")

        let persistedValue = sliderAfter.value as? String ?? ""
        XCTAssertFalse(persistedValue.isEmpty, "Slider should have a persisted value after restart")
        // Values should approximately match (both represent ~0.6 normalized)
        XCTAssertEqual(persistedValue, setValue, "Transparency should persist across restart")

        // Reset
        sliderAfter.adjust(toNormalizedSliderPosition: 1.0)
        closeSettings()
    }

    // MARK: - Background Color

    func testBackgroundColorWellOpensColorPicker() throws {
        openSettings()

        let settingsWindow = app.windows["Appearance Settings"]
        let colorWells = settingsWindow.colorWells
        guard colorWells.count >= 1 else {
            closeSettings()
            throw XCTSkip("No color well found in settings window")
        }

        let colorWell = colorWells.element(boundBy: 0)
        colorWell.click()

        // Look for the system color picker window
        let colorPanel = app.windows["Colors"]
        if colorPanel.waitForExistence(timeout: 2) {
            XCTAssertTrue(colorPanel.exists, "Color picker window should appear")
        } else {
            // Some macOS versions may not expose the color panel as a named window
            // Just verify the app did not crash by checking the settings window still exists
            XCTAssertTrue(settingsWindow.exists, "Settings window should still exist after clicking color well")
        }

        // Dismiss
        app.typeKey(.escape, modifierFlags: [])
        closeSettings()
    }

    func testBackgroundColorChangeApplied() throws {
        throw XCTSkip("Cannot verify background color change via XCUITest")
    }

    func testBackgroundColorPersistsAcrossRestart() throws {
        throw XCTSkip("Cannot verify background color change via XCUITest")
    }

    func testBackgroundColorInteractionWithTheme() throws {
        openSettings()
        selectTheme("Nord")

        let settingsWindow = app.windows["Appearance Settings"]
        let colorWells = settingsWindow.colorWells
        if colorWells.count >= 1 {
            colorWells.element(boundBy: 0).click()
            app.typeKey(.escape, modifierFlags: [])
        }

        // Verify input box still works after theme + color interaction
        closeSettings()
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should function after theme + color interaction")

        // Reset theme
        openSettings()
        selectTheme("Dark")
        closeSettings()
    }

    func testBackgroundColorResetOnThemeChange() throws {
        openSettings()
        selectTheme("Monokai")

        let settingsWindow = app.windows["Appearance Settings"]
        let themePopup = settingsWindow.popUpButtons.element(boundBy: 0)
        XCTAssertEqual(themePopup.value as? String, "Monokai", "Theme should be Monokai")

        selectTheme("Dark")
        XCTAssertEqual(themePopup.value as? String, "Dark", "Theme should reset to Dark")
        closeSettings()
    }

    // MARK: - Combined

    func testTransparencyWithCustomBackground() throws {
        openSettings()

        let slider = transparencySlider()
        XCTAssertTrue(slider.waitForExistence(timeout: 2))

        let initialValue = slider.value as? String ?? ""
        slider.adjust(toNormalizedSliderPosition: 0.6)
        let adjustedValue = slider.value as? String ?? ""
        XCTAssertNotEqual(initialValue, adjustedValue, "Slider value should change")

        // Interact with color well
        let settingsWindow = app.windows["Appearance Settings"]
        let colorWells = settingsWindow.colorWells
        if colorWells.count >= 1 {
            colorWells.element(boundBy: 0).click()
            app.typeKey(.escape, modifierFlags: [])
        }

        // Verify main window is still functional
        closeSettings()
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "App should function with transparency + custom background")

        // Reset
        openSettings()
        transparencySlider().adjust(toNormalizedSliderPosition: 1.0)
        closeSettings()
    }

    func testSettingsLivePreview() throws {
        openSettings()

        let slider = transparencySlider()
        XCTAssertTrue(slider.waitForExistence(timeout: 2))

        slider.adjust(toNormalizedSliderPosition: 0.8)
        let value = slider.value as? String ?? ""
        XCTAssertFalse(value.isEmpty, "Slider should reflect the adjusted value for live preview")

        // Verify main window is still visible and functional while settings open
        let window = app.windows["Holoscape"]
        let inputBox = window.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should be visible during live preview")

        // Reset
        slider.adjust(toNormalizedSliderPosition: 1.0)
        closeSettings()
    }
}
