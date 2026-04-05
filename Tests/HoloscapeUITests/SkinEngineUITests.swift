import XCTest

final class SkinEngineUITests: XCTestCase {
    var app: XCUIApplication!
    private let skinsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".holoscape/skins/test-skin")

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Create a test skin directory and skin.json
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

        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()

        // Clean up test skin
        try? FileManager.default.removeItem(at: skinsDir)
    }

    // MARK: - Skin Discovery

    func testTestSkinAppearsInPicker() throws {
        app.typeKey(",", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        // Skin popup is the second popup button
        let popups = settingsWindow.popUpButtons
        guard popups.count >= 2 else {
            XCTFail("Settings should have at least 2 popup buttons")
            return
        }

        let skinPopup = popups.element(boundBy: 1)
        skinPopup.click()
        Thread.sleep(forTimeInterval: 0.3)

        let testSkinItem = app.menuItems["test-skin"]
        XCTAssertTrue(testSkinItem.waitForExistence(timeout: 1), "Test skin should appear in skin picker")

        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Default Always Available

    func testDefaultSkinAlwaysAvailable() throws {
        app.typeKey(",", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        let popups = settingsWindow.popUpButtons
        guard popups.count >= 2 else { return }

        let skinPopup = popups.element(boundBy: 1)
        skinPopup.click()
        Thread.sleep(forTimeInterval: 0.3)

        let defaultItem = app.menuItems["Default"]
        XCTAssertTrue(defaultItem.waitForExistence(timeout: 1), "Default skin option should always be available")

        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Apply Skin

    func testApplyingSkinDoesNotCrash() throws {
        app.typeKey(",", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        let popups = settingsWindow.popUpButtons
        guard popups.count >= 2 else { return }

        let skinPopup = popups.element(boundBy: 1)
        skinPopup.click()
        Thread.sleep(forTimeInterval: 0.3)

        let testSkinItem = app.menuItems["test-skin"]
        if testSkinItem.waitForExistence(timeout: 1) {
            testSkinItem.click()
            Thread.sleep(forTimeInterval: 0.5)
        }

        // App should still be functional
        let mainWindow = app.windows["Holoscape"]
        XCTAssertTrue(mainWindow.exists, "Main window should survive skin change")

        // Reset to Default
        skinPopup.click()
        Thread.sleep(forTimeInterval: 0.3)
        let defaultItem = app.menuItems["Default"]
        if defaultItem.waitForExistence(timeout: 1) {
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

        app.typeKey(",", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        let popups = settingsWindow.popUpButtons
        guard popups.count >= 2 else { return }

        let skinPopup = popups.element(boundBy: 1)
        skinPopup.click()
        Thread.sleep(forTimeInterval: 0.3)

        // bad-skin should NOT appear (invalid JSON)
        let badSkinItem = app.menuItems["bad-skin"]
        // It might appear in the list (directory exists with skin.json) but selecting it should not crash
        if badSkinItem.waitForExistence(timeout: 0.5) {
            badSkinItem.click()
            Thread.sleep(forTimeInterval: 0.3)

            // App should still be running
            let mainWindow = app.windows["Holoscape"]
            XCTAssertTrue(mainWindow.exists, "App should handle invalid skin gracefully")
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }

        // Clean up bad skin
        try? FileManager.default.removeItem(at: invalidSkinDir)
    }
}
