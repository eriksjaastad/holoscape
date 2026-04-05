import XCTest

final class FontSettingsUITests: HoloscapeUITestCase {

    // MARK: - Font Family Application

    func testApplySFMonoFont() throws {
        openSettings()
        selectFont("SF Mono")
        XCTAssertEqual(currentFontValue(), "SF Mono", "Font popup should reflect SF Mono")
        closeSettings()
    }

    func testApplyMenloFont() throws {
        openSettings()
        selectFont("Menlo")
        XCTAssertEqual(currentFontValue(), "Menlo", "Font popup should reflect Menlo")
        closeSettings()
        openSettings()
        selectFont("SF Mono")
        closeSettings()
    }

    func testApplyMonacoFont() throws {
        openSettings()
        selectFont("Monaco")
        XCTAssertEqual(currentFontValue(), "Monaco", "Font popup should reflect Monaco")
        closeSettings()
        openSettings()
        selectFont("SF Mono")
        closeSettings()
    }

    func testApplyCourierNewFont() throws {
        openSettings()
        selectFont("Courier New")
        XCTAssertEqual(currentFontValue(), "Courier New", "Font popup should reflect Courier New")
        closeSettings()
        openSettings()
        selectFont("SF Mono")
        closeSettings()
    }

    func testApplyFiraCodeFont() throws {
        try skipUnlessFontAvailable("Fira Code")
        openSettings()
        selectFont("Fira Code")
        XCTAssertEqual(currentFontValue(), "Fira Code", "Font popup should reflect Fira Code")
        closeSettings()
        openSettings()
        selectFont("SF Mono")
        closeSettings()
    }

    func testApplyJetBrainsMonoFont() throws {
        try skipUnlessFontAvailable("JetBrains Mono")
        openSettings()
        selectFont("JetBrains Mono")
        XCTAssertEqual(currentFontValue(), "JetBrains Mono", "Font popup should reflect JetBrains Mono")
        closeSettings()
        openSettings()
        selectFont("SF Mono")
        closeSettings()
    }

    // MARK: - Font Size

    func testFontSizeChange() throws {
        openSettings()
        setFontSize("14")
        XCTAssertEqual(currentFontSizeValue(), "14", "Font size field should reflect 14")
        setFontSize("13")
        closeSettings()
    }

    func testFontSizeExtremeLowAccepted() throws {
        openSettings()
        setFontSize("1")
        let value = currentFontSizeValue()
        XCTAssertFalse(value.isEmpty, "Font size field should have a value after setting size 1")
        XCTAssertNotNil(Int(value), "Font size field should contain a numeric value, got: \(value)")
        setFontSize("13")
        closeSettings()
    }

    func testFontSizeExtremeHighAccepted() throws {
        openSettings()
        setFontSize("200")
        let value = currentFontSizeValue()
        XCTAssertFalse(value.isEmpty, "Font size field should have a value after setting size 200")
        XCTAssertNotNil(Int(value), "Font size field should contain a numeric value, got: \(value)")
        setFontSize("13")
        closeSettings()
    }

    func testFontSizeNonNumericRejected() throws {
        openSettings()
        // Record current size before attempting invalid input
        let before = currentFontSizeValue()
        setFontSize("abc")
        let after = currentFontSizeValue()
        XCTAssertNotEqual(after, "abc", "Non-numeric input should be rejected")
        // It should either revert to the previous value or be empty
        XCTAssertTrue(after == before || after.isEmpty || Int(after) != nil,
                       "Font size should revert or be numeric after rejecting non-numeric input, got: \(after)")
        closeSettings()
    }

    // MARK: - Persistence

    func testFontFamilyPersistsAcrossRestart() throws {
        try skipUnlessFontAvailable("Fira Code")
        openSettings()
        selectFont("Fira Code")
        XCTAssertEqual(currentFontValue(), "Fira Code")
        closeSettings()

        // Quit and relaunch
        app.terminate()
        app = XCUIApplication()
        app.launch()

        openSettings()
        XCTAssertEqual(currentFontValue(), "Fira Code", "Font family should persist across restart")

        // Reset
        selectFont("SF Mono")
        closeSettings()
    }

    func testFontSizePersistsAcrossRestart() throws {
        openSettings()
        setFontSize("16")
        XCTAssertEqual(currentFontSizeValue(), "16")
        closeSettings()

        // Quit and relaunch
        app.terminate()
        app = XCUIApplication()
        app.launch()

        openSettings()
        XCTAssertEqual(currentFontSizeValue(), "16", "Font size should persist across restart")

        // Reset
        setFontSize("13")
        closeSettings()
    }

    // MARK: - Application Scope

    func testChannelsSwitchableAfterFontChange() throws {
        openSettings()
        selectFont("Menlo")
        XCTAssertEqual(currentFontValue(), "Menlo")
        closeSettings()

        // Create second channel and switch between them
        createChannel(type: "Shell")

        app.typeKey("1", modifierFlags: .command)
        let first = sidebarEntry("Shell")
        XCTAssertTrue(first.waitForExistence(timeout: 2), "First channel should be accessible after font change")

        app.typeKey("2", modifierFlags: .command)
        let second = sidebarEntry("Shell 2")
        XCTAssertTrue(second.waitForExistence(timeout: 2), "Second channel should be accessible after font change")

        openSettings()
        selectFont("SF Mono")
        closeSettings()
    }

    func testInputBoxAcceptsTextAfterFontChange() throws {
        openSettings()
        selectFont("Monaco")
        closeSettings()

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist with changed font")

        inputBox.typeText("font-test")
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "font-test", "Input box should accept text after font change")

        openSettings()
        selectFont("SF Mono")
        closeSettings()
    }

    func testOutputViewExistsAfterFontChange() throws {
        openSettings()
        selectFont("Menlo")
        closeSettings()

        // Generate output
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist")
        inputBox.typeText("echo font-output-test")
        inputBox.typeKey(.return, modifierFlags: [])

        let window = app.windows["Holoscape"]
        let scrollViews = window.scrollViews
        XCTAssertGreaterThanOrEqual(scrollViews.count, 1, "Output scroll view should exist after font change")

        openSettings()
        selectFont("SF Mono")
        closeSettings()
    }

    func testSplitPanesWorkAfterFontChange() throws {
        // Create split
        app.typeKey("d", modifierFlags: .command)

        openSettings()
        selectFont("Courier New")
        XCTAssertEqual(currentFontValue(), "Courier New")
        closeSettings()

        let window = app.windows["Holoscape"]
        let scrollViews = window.scrollViews
        XCTAssertGreaterThanOrEqual(scrollViews.count, 1, "Split panes should still exist after font change")

        openSettings()
        selectFont("SF Mono")
        closeSettings()
    }
}
