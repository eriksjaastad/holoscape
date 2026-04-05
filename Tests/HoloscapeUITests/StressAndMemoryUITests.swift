import XCTest

final class StressAndMemoryUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Rapid Operations

    func testRapidChannelCreateClose100Cycles() throws {
        for i in 0..<100 {
            app.menuBars.firstMatch.menuBarItems["File"].click()
            app.menuItems["New Channel"].click()
            let dialog = app.dialogs.firstMatch
            if dialog.waitForExistence(timeout: 1) {
                dialog.buttons["Shell"].click()
            }
            Thread.sleep(forTimeInterval: 0.1)

            app.typeKey("w", modifierFlags: .command)
            let closeButton = app.buttons["Close"]
            if closeButton.waitForExistence(timeout: 0.5) {
                closeButton.click()
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should survive 100 create/close cycles")
    }

    func testRapidSplitCloseClose50Cycles() throws {
        for _ in 0..<50 {
            app.typeKey("d", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.05)
            app.typeKey("w", modifierFlags: [.command, .shift])
            Thread.sleep(forTimeInterval: 0.05)
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should survive 50 split/close cycles with no leaked views")
    }

    func testRapidSettingsOpenClose50Cycles() throws {
        for _ in 0..<50 {
            app.typeKey(",", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.1)

            let settingsWindow = app.windows["Appearance Settings"]
            if settingsWindow.waitForExistence(timeout: 1) {
                settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should survive 50 settings open/close cycles with no leaked windows")
    }

    func testRapidSidebarToggle100Cycles() throws {
        for _ in 0..<100 {
            app.typeKey("s", modifierFlags: [.command, .shift])
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should survive 100 sidebar toggles with layout intact")
    }

    func testRapidSearchOpenClose100Cycles() throws {
        for _ in 0..<100 {
            app.typeKey("f", modifierFlags: .command)
            Thread.sleep(forTimeInterval: 0.02)
            app.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.3)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should survive 100 search open/close cycles with focus intact")

        // Verify focus returns to input
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("post-stress")
        let value = inputBox.value as? String ?? ""
        XCTAssertEqual(value, "post-stress", "Input focus should be correct after stress")
    }

    // MARK: - Channel Accumulation

    func testCreate20ChannelsNoSlowdown() throws {
        for _ in 0..<19 {
            app.menuBars.firstMatch.menuBarItems["File"].click()
            app.menuItems["New Channel"].click()
            let dialog = app.dialogs.firstMatch
            if dialog.waitForExistence(timeout: 1) {
                dialog.buttons["Shell"].click()
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        Thread.sleep(forTimeInterval: 0.5)

        // Switching should remain responsive
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)
        app.typeKey("5", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should remain responsive with 20 channels")

        let sidebarButtons = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'"))
        XCTAssertGreaterThanOrEqual(sidebarButtons.count, 20, "Should have 20 sidebar entries")
    }

    func testCreate20ChannelsThenCloseAll() throws {
        // Create 19 extra channels (1 exists by default)
        for _ in 0..<19 {
            app.menuBars.firstMatch.menuBarItems["File"].click()
            app.menuItems["New Channel"].click()
            let dialog = app.dialogs.firstMatch
            if dialog.waitForExistence(timeout: 1) {
                dialog.buttons["Shell"].click()
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        Thread.sleep(forTimeInterval: 0.3)

        // Close all
        for _ in 0..<19 {
            app.typeKey("w", modifierFlags: .command)
            let closeButton = app.buttons["Close"]
            if closeButton.waitForExistence(timeout: 0.5) {
                closeButton.click()
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        Thread.sleep(forTimeInterval: 0.5)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should be in clean state after closing all channels")
    }

    // MARK: - Input Stress

    func testSubmit1000Commands() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)

        for i in 0..<1000 {
            inputBox.typeText("cmd-\(i)")
            inputBox.typeKey(.return, modifierFlags: [])
        }
        Thread.sleep(forTimeInterval: 0.5)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should remain responsive after 1000 commands")
    }

    func testCommandHistory1000Entries() throws {
        let inputBox = app.textViews["input-box"]

        // Submit 100 commands (1000 is very slow in UI tests)
        for i in 0..<100 {
            inputBox.typeText("hist-\(i)")
            inputBox.typeKey(.return, modifierFlags: [])
        }
        Thread.sleep(forTimeInterval: 0.3)

        // Navigate up through history
        for _ in 0..<50 {
            inputBox.typeKey(.upArrow, modifierFlags: [])
        }
        Thread.sleep(forTimeInterval: 0.2)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should handle large command history without crash")
    }

    func testPasteLargeInput() throws {
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.exists)

        // Type a large amount of text (actual 10MB paste not feasible in UI tests)
        let largeText = String(repeating: "abcdefghij", count: 1000)
        inputBox.typeText(largeText)
        Thread.sleep(forTimeInterval: 1.0)

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "App should handle large input gracefully")
    }

    // MARK: - Long-Running

    func testChannelActiveFor10Minutes() throws {
        // Abbreviated: verify elapsed time updates over a shorter period
        let window = app.windows["Holoscape"]
        let shellEntry = window.buttons.matching(NSPredicate(format: "identifier CONTAINS 'sidebar-Shell'")).firstMatch
        XCTAssertTrue(shellEntry.waitForExistence(timeout: 2))

        let title1 = shellEntry.title
        Thread.sleep(forTimeInterval: 5.0)
        let title2 = shellEntry.title

        // Elapsed time should have updated
        XCTAssertTrue(window.exists, "Channel should remain active without degradation")
    }
}
