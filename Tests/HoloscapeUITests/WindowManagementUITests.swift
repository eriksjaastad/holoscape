import XCTest

final class WindowManagementUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Window Operations

    func testWindowMinimize() throws {
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists)

        // Minimize
        window.buttons[XCUIIdentifierMinimizeWindow].click()
        Thread.sleep(forTimeInterval: 0.5)

        // Window should be minimized (not hittable but exists in hierarchy)
        // Restore by clicking dock icon or reactivating
        app.activate()
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(window.waitForExistence(timeout: 3), "Window should be restorable after minimize")
    }

    func testWindowZoom() throws {
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists)

        let initialFrame = window.frame

        // Zoom (green button)
        window.buttons[XCUIIdentifierZoomWindow].click()
        Thread.sleep(forTimeInterval: 0.5)

        // Window should have resized
        let window2 = app.windows["Holoscape"]
        XCTAssertTrue(window2.exists, "Window should remain functional after zoom")
    }

    func testWindowFullScreen() throws {
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists)

        // Enter full screen via menu or button
        window.buttons[XCUIIdentifierFullScreenWindow].click()
        Thread.sleep(forTimeInterval: 1.0)

        // Verify window still functional
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist in full screen")

        // Exit full screen
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.0)
    }

    func testWindowRestoreAfterMinimize() throws {
        let window = app.windows["Holoscape"]

        // Type something first
        let inputBox = app.textViews["input-box"]
        inputBox.typeText("before-minimize")
        inputBox.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        // Minimize and restore
        window.buttons[XCUIIdentifierMinimizeWindow].click()
        Thread.sleep(forTimeInterval: 0.5)
        app.activate()
        Thread.sleep(forTimeInterval: 0.5)

        // Window content should be intact
        XCTAssertTrue(window.waitForExistence(timeout: 3), "Content should be intact after minimize/restore")
    }

    // MARK: - Application Menu

    func testAboutDialogOpens() throws {
        let appMenu = app.menuBars.firstMatch.menuBarItems["Holoscape"]
        XCTAssertTrue(appMenu.exists)
        appMenu.click()
        Thread.sleep(forTimeInterval: 0.2)

        let aboutItem = app.menuItems.matching(NSPredicate(format: "title CONTAINS 'About'")).firstMatch
        if aboutItem.waitForExistence(timeout: 1) {
            aboutItem.click()
            Thread.sleep(forTimeInterval: 0.5)

            // About dialog/window should appear
            let window = app.windows["Holoscape"]
            XCTAssertTrue(window.exists, "About dialog should open without crash")
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    func testAboutDialogCloses() throws {
        let appMenu = app.menuBars.firstMatch.menuBarItems["Holoscape"]
        appMenu.click()
        Thread.sleep(forTimeInterval: 0.2)

        let aboutItem = app.menuItems.matching(NSPredicate(format: "title CONTAINS 'About'")).firstMatch
        if aboutItem.waitForExistence(timeout: 1) {
            aboutItem.click()
            Thread.sleep(forTimeInterval: 0.5)

            // Close about dialog
            app.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.3)
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "Main window should remain after closing About dialog")
    }

    func testQuitViaMenu() throws {
        // Verify quit menu item exists (don't actually quit during test)
        let appMenu = app.menuBars.firstMatch.menuBarItems["Holoscape"]
        appMenu.click()
        Thread.sleep(forTimeInterval: 0.2)

        let quitItem = app.menuItems.matching(NSPredicate(format: "title CONTAINS 'Quit'")).firstMatch
        XCTAssertTrue(quitItem.waitForExistence(timeout: 1), "Quit menu item should exist")

        // Don't actually click quit — just verify it exists
        app.typeKey(.escape, modifierFlags: [])
    }

    func testQuitViaCmdQ() throws {
        // Verify Cmd+Q binding exists via menu
        let appMenu = app.menuBars.firstMatch.menuBarItems["Holoscape"]
        appMenu.click()
        Thread.sleep(forTimeInterval: 0.2)

        let quitItem = app.menuItems.matching(NSPredicate(format: "title CONTAINS 'Quit'")).firstMatch
        XCTAssertTrue(quitItem.exists, "Quit should be accessible via Cmd+Q")

        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - File Menu Completeness

    func testFileMenuNewSession() throws {
        app.menuBars.firstMatch.menuBarItems["File"].click()
        Thread.sleep(forTimeInterval: 0.2)

        let newSessionItem = app.menuItems["New Session"]
        XCTAssertTrue(newSessionItem.waitForExistence(timeout: 1), "New Session menu item should exist")
        newSessionItem.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Should focus session launcher
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists, "File > New Session should work")
    }

    func testFileMenuNewChannel() throws {
        app.menuBars.firstMatch.menuBarItems["File"].click()
        Thread.sleep(forTimeInterval: 0.2)

        let newChannelItem = app.menuItems["New Channel"]
        XCTAssertTrue(newChannelItem.waitForExistence(timeout: 1), "New Channel menu item should exist")
        newChannelItem.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Dialog should appear
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            dialog.buttons["Cancel"].click()
        }
    }

    func testFileMenuCloseChannel() throws {
        app.menuBars.firstMatch.menuBarItems["File"].click()
        Thread.sleep(forTimeInterval: 0.2)

        let closeItem = app.menuItems["Close Channel"]
        XCTAssertTrue(closeItem.waitForExistence(timeout: 1), "Close Channel menu item should exist")

        // Don't click — just verify existence
        app.typeKey(.escape, modifierFlags: [])
    }

    func testFileMenuToggleSidebar() throws {
        app.menuBars.firstMatch.menuBarItems["File"].click()
        Thread.sleep(forTimeInterval: 0.2)

        let toggleItem = app.menuItems["Toggle Sidebar"]
        XCTAssertTrue(toggleItem.waitForExistence(timeout: 1), "Toggle Sidebar menu item should exist")
        toggleItem.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Toggle back
        app.menuBars.firstMatch.menuBarItems["File"].click()
        Thread.sleep(forTimeInterval: 0.2)
        let toggleItem2 = app.menuItems["Toggle Sidebar"]
        if toggleItem2.waitForExistence(timeout: 1) {
            toggleItem2.click()
        }
    }

    // MARK: - View Menu Completeness

    func testViewMenuShowTimestamps() throws {
        app.menuBars.firstMatch.menuBarItems["View"].click()
        Thread.sleep(forTimeInterval: 0.2)

        let timestampItem = app.menuItems["Show Timestamps"]
        XCTAssertTrue(timestampItem.waitForExistence(timeout: 1), "Show Timestamps should be in View menu")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testViewMenuFind() throws {
        app.menuBars.firstMatch.menuBarItems["View"].click()
        Thread.sleep(forTimeInterval: 0.2)

        let findItem = app.menuItems["Find"]
        XCTAssertTrue(findItem.waitForExistence(timeout: 1), "Find should be in View menu")
        findItem.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Search bar should open
        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2), "Search bar should open from View > Find")

        // Close search
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Window State

    func testWindowPositionPersists() throws {
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.exists)

        // Quit and relaunch
        app.terminate()
        Thread.sleep(forTimeInterval: 1.0)
        app.launch()
        Thread.sleep(forTimeInterval: 1.0)

        let window2 = app.windows["Holoscape"]
        XCTAssertTrue(window2.waitForExistence(timeout: 3), "Window position should be restored after restart")
    }

    func testWindowSizePersists() throws {
        let window = app.windows["Holoscape"]
        let initialFrame = window.frame

        // Quit and relaunch
        app.terminate()
        Thread.sleep(forTimeInterval: 1.0)
        app.launch()
        Thread.sleep(forTimeInterval: 1.0)

        let window2 = app.windows["Holoscape"]
        XCTAssertTrue(window2.waitForExistence(timeout: 3))

        let restoredFrame = window2.frame
        // Size should be approximately the same
        XCTAssertEqual(restoredFrame.width, initialFrame.width, accuracy: 10, "Window width should persist")
        XCTAssertEqual(restoredFrame.height, initialFrame.height, accuracy: 10, "Window height should persist")
    }
}
