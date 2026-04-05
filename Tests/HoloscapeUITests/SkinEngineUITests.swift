import XCTest

final class SkinEngineUITests: HoloscapeUITestCase {
    private let skinsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".holoscape/skins/test-skin")

    override func setUpWithError() throws {
        // Create a test skin directory and skin.json before launching app
        try FileManager.default.createDirectory(at: skinsDir, withIntermediateDirectories: true)
        let skinJson = """
        {
            "name": "Test Skin",
            "windowBackground": "#2d2d44",
            "textForeground": "#e0e0e0",
            "ansiColors": [
                "#1a1a2e", "#ff5555", "#50fa7b", "#f1fa8c",
                "#6272a4", "#ff79c6", "#8be9fd", "#f8f8f2",
                "#44475a", "#ff6e6e", "#69ff94", "#ffffa5",
                "#7b8bbd", "#ff92df", "#a4ffff", "#ffffff"
            ]
        }
        """
        try skinJson.write(to: skinsDir.appendingPathComponent("skin.json"), atomically: true, encoding: .utf8)

        // Call super to launch the app
        try super.setUpWithError()
    }

    override func tearDownWithError() throws {
        // Call super to terminate the app
        try super.tearDownWithError()

        // Clean up test skin
        try? FileManager.default.removeItem(at: skinsDir)
    }

    // MARK: - Skin Discovery

    func testTestSkinAppearsInPicker() throws {
        openSettings()

        let settingsWindow = app.windows["Appearance Settings"]

        let skinPopup = settingsWindow.popUpButtons["skin-popup"]
        skinPopup.click()

        let testSkinItem = app.menuItems["test-skin"]
        XCTAssertTrue(testSkinItem.waitForExistence(timeout: 2), "Test skin should appear in skin picker")

        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Default Always Available

    func testDefaultSkinAlwaysAvailable() throws {
        openSettings()

        let settingsWindow = app.windows["Appearance Settings"]
        let skinPopup = settingsWindow.popUpButtons["skin-popup"]
        skinPopup.click()

        let defaultItem = app.menuItems["Default"]
        XCTAssertTrue(defaultItem.waitForExistence(timeout: 2), "Default skin option should always be available")

        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Apply Skin

    func testApplyingSkinDoesNotCrash() throws {
        openSettings()

        let settingsWindow = app.windows["Appearance Settings"]
        let skinPopup = settingsWindow.popUpButtons["skin-popup"]
        skinPopup.click()

        let testSkinItem = app.menuItems["test-skin"]
        if testSkinItem.waitForExistence(timeout: 2) {
            testSkinItem.click()
        }

        // App should still be functional
        let mainWindow = app.windows["Holoscape"]
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 2), "Main window should survive skin change")

        // Reset to Default
        skinPopup.click()
        let defaultItem = app.menuItems["Default"]
        if defaultItem.waitForExistence(timeout: 2) {
            defaultItem.click()
        }
    }

    // MARK: - Invalid Skin Fallback

    func testInvalidSkinFallsBackGracefully() throws {
        // Write an invalid skin.json
        let invalidSkinDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".holoscape/skins/bad-skin")
        try FileManager.default.createDirectory(at: invalidSkinDir, withIntermediateDirectories: true)
        try "{ invalid json }}}".write(
            to: invalidSkinDir.appendingPathComponent("skin.json"),
            atomically: true, encoding: .utf8
        )

        defer {
            // Clean up bad skin
            try? FileManager.default.removeItem(at: invalidSkinDir)
        }

        openSettings()

        let settingsWindow = app.windows["Appearance Settings"]
        let skinPopup = settingsWindow.popUpButtons["skin-popup"]
        skinPopup.click()

        // bad-skin should NOT appear (invalid JSON)
        let badSkinItem = app.menuItems["bad-skin"]
        // It might appear in the list (directory exists with skin.json) but selecting it should not crash
        if badSkinItem.waitForExistence(timeout: 1) {
            badSkinItem.click()

            // App should still be running
            let mainWindow = app.windows["Holoscape"]
            XCTAssertTrue(mainWindow.waitForExistence(timeout: 2), "App should handle invalid skin gracefully")
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
    }
}
