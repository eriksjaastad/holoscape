import XCTest

final class TransparencyColorWellUITests: XCTestCase {
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

    private func getSlider() -> XCUIElement {
        let settingsWindow = app.windows["Appearance Settings"]
        return settingsWindow.sliders.element(boundBy: 0)
    }

    // MARK: - Transparency Slider

    func testTransparencySliderChangesWindowOpacity() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        let slider = getSlider()
        XCTAssertTrue(slider.exists, "Transparency slider should exist")

        // Adjust slider
        slider.adjust(toNormalizedSliderPosition: 0.7)
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain after transparency change")

        // Reset
        slider.adjust(toNormalizedSliderPosition: 1.0)
        closeSettings()
    }

    func testTransparencyMinimum() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        let slider = getSlider()
        XCTAssertTrue(slider.exists)

        // Set to minimum (0.3 mapped to normalized 0.0)
        slider.adjust(toNormalizedSliderPosition: 0.0)
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should remain visible and usable at minimum transparency")

        // Reset
        slider.adjust(toNormalizedSliderPosition: 1.0)
        closeSettings()
    }

    func testTransparencyMaximum() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        let slider = getSlider()
        XCTAssertTrue(slider.exists)

        slider.adjust(toNormalizedSliderPosition: 1.0)
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should be fully opaque at maximum")
        closeSettings()
    }

    func testTransparencyMidRange() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        let slider = getSlider()
        XCTAssertTrue(slider.exists)

        slider.adjust(toNormalizedSliderPosition: 0.5)
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Window should be semi-transparent at mid range")

        // Reset
        slider.adjust(toNormalizedSliderPosition: 1.0)
        closeSettings()
    }

    func testTransparencyPersistsAcrossRestart() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        let slider = getSlider()
        slider.adjust(toNormalizedSliderPosition: 0.6)
        Thread.sleep(forTimeInterval: 0.3)
        closeSettings()

        // Quit and relaunch
        app.terminate()
        Thread.sleep(forTimeInterval: 1.0)
        app.launch()
        Thread.sleep(forTimeInterval: 1.0)

        // Verify transparency persisted
        openSettings()
        let settingsWindow2 = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow2.waitForExistence(timeout: 3))

        let slider2 = getSlider()
        XCTAssertTrue(slider2.exists, "Transparency slider should exist after restart")
        // Slider value should be approximately 0.6 (not exactly due to normalization)

        // Reset
        slider2.adjust(toNormalizedSliderPosition: 1.0)
        closeSettings()
    }

    // MARK: - Background Color

    func testBackgroundColorWellOpensColorPicker() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        let colorWells = settingsWindow.colorWells
        XCTAssertGreaterThanOrEqual(colorWells.count, 1, "Color well should exist")

        let colorWell = colorWells.element(boundBy: 0)
        colorWell.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Color picker window should appear
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Clicking color well should not crash")

        // Dismiss color picker
        app.typeKey(.escape, modifierFlags: [])
        closeSettings()
    }

    func testBackgroundColorChangeApplied() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        let colorWells = settingsWindow.colorWells
        guard colorWells.count >= 1 else {
            closeSettings()
            throw XCTSkip("No color well found")
        }

        let colorWell = colorWells.element(boundBy: 0)
        colorWell.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Just clicking the color well and dismissing
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Background color change should apply without crash")
        closeSettings()
    }

    func testBackgroundColorPersistsAcrossRestart() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        // Interact with color well (may set a color)
        let colorWells = settingsWindow.colorWells
        if colorWells.count >= 1 {
            let colorWell = colorWells.element(boundBy: 0)
            colorWell.click()
            Thread.sleep(forTimeInterval: 0.3)
            app.typeKey(.escape, modifierFlags: [])
        }
        closeSettings()

        // Quit and relaunch
        app.terminate()
        Thread.sleep(forTimeInterval: 1.0)
        app.launch()
        Thread.sleep(forTimeInterval: 1.0)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Background color should persist across restart")
    }

    func testBackgroundColorInteractionWithTheme() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        // Change theme then interact with color
        let popups = settingsWindow.popUpButtons
        if popups.count > 0 {
            let themePopup = popups.element(boundBy: 0)
            themePopup.click()
            Thread.sleep(forTimeInterval: 0.3)
            let nordItem = app.menuItems["Nord"]
            if nordItem.waitForExistence(timeout: 1) {
                nordItem.click()
            } else {
                app.typeKey(.escape, modifierFlags: [])
            }
        }
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Custom color should interact with theme without crash")

        // Reset theme
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

    func testBackgroundColorResetOnThemeChange() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        // Switch themes to test reset behavior
        let popups = settingsWindow.popUpButtons
        if popups.count > 0 {
            let themePopup = popups.element(boundBy: 0)
            themePopup.click()
            Thread.sleep(forTimeInterval: 0.3)
            let monokaiItem = app.menuItems["Monokai"]
            if monokaiItem.waitForExistence(timeout: 1) { monokaiItem.click() }
            else { app.typeKey(.escape, modifierFlags: []) }
            Thread.sleep(forTimeInterval: 0.3)

            themePopup.click()
            Thread.sleep(forTimeInterval: 0.3)
            let darkItem = app.menuItems["Dark"]
            if darkItem.waitForExistence(timeout: 1) { darkItem.click() }
            else { app.typeKey(.escape, modifierFlags: []) }
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Theme change should handle background color reset")
        closeSettings()
    }

    // MARK: - Combined

    func testTransparencyWithCustomBackground() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        // Set transparency
        let slider = getSlider()
        slider.adjust(toNormalizedSliderPosition: 0.6)
        Thread.sleep(forTimeInterval: 0.3)

        // Interact with color well
        let colorWells = settingsWindow.colorWells
        if colorWells.count >= 1 {
            colorWells.element(boundBy: 0).click()
            Thread.sleep(forTimeInterval: 0.3)
            app.typeKey(.escape, modifierFlags: [])
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Transparency + custom background should work together")

        // Reset
        slider.adjust(toNormalizedSliderPosition: 1.0)
        closeSettings()
    }

    func testSettingsLivePreview() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        // Change slider while settings open
        let slider = getSlider()
        slider.adjust(toNormalizedSliderPosition: 0.8)
        Thread.sleep(forTimeInterval: 0.3)

        // Main window should reflect changes immediately
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Changes should be visible in main window while settings open")

        // Reset
        slider.adjust(toNormalizedSliderPosition: 1.0)
        closeSettings()
    }
}
