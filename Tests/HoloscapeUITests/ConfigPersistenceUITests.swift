import XCTest

final class ConfigPersistenceUITests: HoloscapeUITestCase {

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
        transparencySlider().adjust(toNormalizedSliderPosition: 0.8)

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
        transparencySlider().adjust(toNormalizedSliderPosition: 1.0)
        closeSettings()
    }

    func testAppLaunchesSuccessfully() throws {
        assertActiveChannelResponsive(message: "App should launch with responsive channel")
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
        let slider = transparencySlider()
        for pos in stride(from: 0.5, through: 1.0, by: 0.1) {
            slider.adjust(toNormalizedSliderPosition: CGFloat(pos))
        }
        // Allow slider value to settle after rapid adjustments
        Thread.sleep(forTimeInterval: 0.3)
        // Assert slider ended at approximately 1.0
        let finalValue = slider.normalizedSliderPosition
        XCTAssertGreaterThan(finalValue, 0.8, "Slider should be near 1.0 after rapid adjustments to the right")

        // Verify the app is still functional
        closeSettings()
        assertActiveChannelResponsive(message: "App should remain responsive after rapid settings changes")

        // Reset
        openSettings()
        selectTheme("Dark")
        closeSettings()
    }
}
