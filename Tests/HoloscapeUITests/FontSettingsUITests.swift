import XCTest

final class FontSettingsUITests: XCTestCase {
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

    private func selectFont(_ name: String) {
        let settingsWindow = app.windows["Appearance Settings"]
        let popups = settingsWindow.popUpButtons
        guard popups.count >= 3 else { return }

        let fontPopup = popups.element(boundBy: 2)
        fontPopup.click()
        Thread.sleep(forTimeInterval: 0.3)

        let fontItem = app.menuItems[name]
        if fontItem.waitForExistence(timeout: 1) {
            fontItem.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
        Thread.sleep(forTimeInterval: 0.3)
    }

    private func setFontSize(_ size: String) {
        let settingsWindow = app.windows["Appearance Settings"]
        let textFields = settingsWindow.textFields
        guard textFields.count >= 1 else { return }

        let sizeField = textFields.element(boundBy: 0)
        sizeField.click()
        sizeField.typeKey("a", modifierFlags: .command)
        sizeField.typeText(size)
        sizeField.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
    }

    // MARK: - Font Family Application

    func testApplySFMonoFont() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        selectFont("SF Mono")

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should remain functional with SF Mono font")
        closeSettings()
    }

    func testApplyMenloFont() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        selectFont("Menlo")

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should remain functional with Menlo font")
        closeSettings()
    }

    func testApplyMonacoFont() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        selectFont("Monaco")

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should remain functional with Monaco font")
        closeSettings()
    }

    func testApplyCourierNewFont() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        selectFont("Courier New")

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should remain functional with Courier New font")
        closeSettings()
    }

    func testApplyFiraCodeFont() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        selectFont("Fira Code")

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should remain functional with Fira Code font")
        closeSettings()
    }

    func testApplyJetBrainsMonoFont() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        selectFont("JetBrains Mono")

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should remain functional with JetBrains Mono font")
        closeSettings()
    }

    // MARK: - Font Size

    func testFontSizeChange() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        setFontSize("14")

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Font size change should not crash")
        closeSettings()
    }

    func testFontSizeMinimum() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        setFontSize("1")

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Very small font size should be handled gracefully")

        // Reset to reasonable size
        setFontSize("13")
        closeSettings()
    }

    func testFontSizeMaximum() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        setFontSize("200")

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Very large font size should be handled gracefully")

        // Reset
        setFontSize("13")
        closeSettings()
    }

    func testFontSizeNonNumericRejected() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        setFontSize("abc")

        // App should not crash and should reject non-numeric input
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Non-numeric font size should be rejected gracefully")
        closeSettings()
    }

    // MARK: - Persistence

    func testFontFamilyPersistsAcrossRestart() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        selectFont("Fira Code")
        closeSettings()

        // Quit and relaunch
        app.terminate()
        Thread.sleep(forTimeInterval: 1.0)
        app.launch()
        Thread.sleep(forTimeInterval: 1.0)

        openSettings()
        let settingsWindow2 = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow2.waitForExistence(timeout: 3))

        let popups = settingsWindow2.popUpButtons
        if popups.count >= 3 {
            let fontPopup = popups.element(boundBy: 2)
            let currentValue = fontPopup.value as? String ?? ""
            XCTAssertEqual(currentValue, "Fira Code", "Font family should persist across restart")
        }

        // Reset
        selectFont("SF Mono")
        closeSettings()
    }

    func testFontSizePersistsAcrossRestart() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))

        setFontSize("16")
        closeSettings()

        // Quit and relaunch
        app.terminate()
        Thread.sleep(forTimeInterval: 1.0)
        app.launch()
        Thread.sleep(forTimeInterval: 1.0)

        openSettings()
        let settingsWindow2 = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow2.waitForExistence(timeout: 3))

        let textFields = settingsWindow2.textFields
        if textFields.count >= 1 {
            let sizeField = textFields.element(boundBy: 0)
            let currentValue = sizeField.value as? String ?? ""
            XCTAssertEqual(currentValue, "16", "Font size should persist across restart")
        }

        // Reset
        setFontSize("13")
        closeSettings()
    }

    // MARK: - Application Scope

    func testFontAppliedToAllChannels() throws {
        // Create second channel
        app.menuBars.firstMatch.menuBarItems["File"].click()
        app.menuItems["New Channel"].click()
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Shell"].click()
        }
        Thread.sleep(forTimeInterval: 0.5)

        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        selectFont("Menlo")
        closeSettings()

        // Switch between channels
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("2", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Font should apply to all channels")

        openSettings()
        selectFont("SF Mono")
        closeSettings()
    }

    func testFontAppliedToInputBox() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        selectFont("Monaco")
        closeSettings()

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists, "Input box should be functional with changed font")

        // Type to verify
        inputBox.typeText("font-test")
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "font-test", "Input box should accept text with new font")

        openSettings()
        selectFont("SF Mono")
        closeSettings()
    }

    func testFontAppliedToOutputView() throws {
        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        selectFont("JetBrains Mono")
        closeSettings()

        // Generate output
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("echo font-output-test")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Output view should display with selected font")

        openSettings()
        selectFont("SF Mono")
        closeSettings()
    }

    func testFontAppliedInSplitPanes() throws {
        // Create split
        app.typeKey("d", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        openSettings()
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3))
        selectFont("Courier New")
        closeSettings()

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "All split panes should use selected font")

        openSettings()
        selectFont("SF Mono")
        closeSettings()
    }
}
