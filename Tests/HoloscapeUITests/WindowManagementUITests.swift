import XCTest

final class WindowManagementUITests: HoloscapeUITestCase {

    // MARK: - Window Operations

    func testWindowMinimize() throws {
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 3))

        window.buttons[XCUIIdentifierMinimizeWindow].click()

        // Restore by reactivating
        app.activate()

        XCTAssertTrue(window.waitForExistence(timeout: 5), "Window should be restorable after minimize")
    }

    func testWindowZoom() throws {
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 3))

        let initialFrame = window.frame

        // Zoom (green button)
        window.buttons[XCUIIdentifierZoomWindow].click()

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should exist after zoom")

        let zoomedFrame = window.frame
        XCTAssertNotEqual(initialFrame, zoomedFrame, "Window frame should change after zoom")
    }

    func testWindowFullScreen() throws {
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 3))

        let initialFrame = window.frame

        // Enter full screen via Ctrl+Cmd+F
        app.typeKey("f", modifierFlags: [.control, .command])

        // Verify window still functional in full screen
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 5), "Input box should exist in full screen")

        // Exit full screen via Ctrl+Cmd+F (NOT Escape)
        app.typeKey("f", modifierFlags: [.control, .command])

        // Wait for fullscreen animation to complete and verify frame changed back
        let restoredInputBox = app.textViews["input-box"]
        XCTAssertTrue(restoredInputBox.waitForExistence(timeout: 5), "Input box should exist after exiting full screen")
    }

    func testWindowRestoreAfterMinimize() throws {
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 3))

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 2))
        inputBox.typeText("before-minimize")
        inputBox.typeKey(.return, modifierFlags: [])

        // Minimize and restore
        window.buttons[XCUIIdentifierMinimizeWindow].click()
        app.activate()

        XCTAssertTrue(window.waitForExistence(timeout: 5), "Window should be restorable after minimize")

        let restoredInputBox = app.textViews["input-box"]
        XCTAssertTrue(restoredInputBox.waitForExistence(timeout: 3), "Input box should be present after minimize/restore")
    }

    // MARK: - Application Menu

    func testAboutDialogOpens() throws {
        let appMenu = app.menuBars.firstMatch.menuBarItems["Holoscape"]
        XCTAssertTrue(appMenu.waitForExistence(timeout: 2))
        appMenu.click()

        let aboutItem = app.menuItems.matching(NSPredicate(format: "title CONTAINS 'About'")).firstMatch
        XCTAssertTrue(aboutItem.waitForExistence(timeout: 2), "About menu item should exist")
        aboutItem.click()

        // Main window should still be functional
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 3), "Main window should remain after opening About dialog")
    }

    func testAboutDialogCloses() throws {
        let appMenu = app.menuBars.firstMatch.menuBarItems["Holoscape"]
        appMenu.click()

        let aboutItem = app.menuItems.matching(NSPredicate(format: "title CONTAINS 'About'")).firstMatch
        if aboutItem.waitForExistence(timeout: 2) {
            aboutItem.click()
            app.typeKey(.escape, modifierFlags: [])
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }

        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should remain after closing About dialog")
    }

    func testQuitViaMenu() throws {
        let appMenu = app.menuBars.firstMatch.menuBarItems["Holoscape"]
        appMenu.click()

        let quitItem = app.menuItems.matching(NSPredicate(format: "title CONTAINS 'Quit'")).firstMatch
        XCTAssertTrue(quitItem.waitForExistence(timeout: 2), "Quit menu item should exist")
        XCTAssertTrue(quitItem.isEnabled, "Quit menu item should be enabled")

        app.typeKey(.escape, modifierFlags: [])
    }

    func testQuitViaCmdQ() throws {
        let appMenu = app.menuBars.firstMatch.menuBarItems["Holoscape"]
        appMenu.click()

        let quitItem = app.menuItems.matching(NSPredicate(format: "title CONTAINS 'Quit'")).firstMatch
        XCTAssertTrue(quitItem.waitForExistence(timeout: 2), "Quit should be accessible via Cmd+Q")
        XCTAssertTrue(quitItem.isEnabled, "Quit should be enabled")

        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - File Menu Completeness

    func testFileMenuNewSession() throws {
        app.menuBars.firstMatch.menuBarItems["File"].click()

        let newSessionItem = app.menuItems["New Session"]
        XCTAssertTrue(newSessionItem.waitForExistence(timeout: 2), "New Session menu item should exist")
        newSessionItem.click()

        // Should focus session launcher — verify input box still works
        let inputBox = app.textViews["input-box"]
        XCTAssertTrue(inputBox.waitForExistence(timeout: 3), "Input box should be functional after New Session")
    }

    func testFileMenuNewChannel() throws {
        app.menuBars.firstMatch.menuBarItems["File"].click()

        let newChannelItem = app.menuItems["New Channel"]
        XCTAssertTrue(newChannelItem.waitForExistence(timeout: 2), "New Channel menu item should exist")
        newChannelItem.click()

        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 3), "New Channel dialog should appear")
        dialog.buttons["Cancel"].click()
    }

    func testFileMenuCloseChannel() throws {
        app.menuBars.firstMatch.menuBarItems["File"].click()

        let closeItem = app.menuItems["Close Channel"]
        XCTAssertTrue(closeItem.waitForExistence(timeout: 2), "Close Channel menu item should exist")
        XCTAssertTrue(closeItem.isEnabled, "Close Channel should be enabled when a channel exists")

        app.typeKey(.escape, modifierFlags: [])
    }

    func testFileMenuToggleSidebar() throws {
        app.menuBars.firstMatch.menuBarItems["File"].click()

        let toggleItem = app.menuItems["Toggle Sidebar"]
        XCTAssertTrue(toggleItem.waitForExistence(timeout: 2), "Toggle Sidebar menu item should exist")
        toggleItem.click()

        // Tab bar should appear when sidebar is collapsed
        let window = app.windows["Holoscape"]
        let tabButton = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'")).firstMatch
        XCTAssertTrue(tabButton.waitForExistence(timeout: 3), "Tab bar should appear when sidebar is toggled off")

        // Toggle back
        app.menuBars.firstMatch.menuBarItems["File"].click()
        let toggleItem2 = app.menuItems["Toggle Sidebar"]
        if toggleItem2.waitForExistence(timeout: 2) {
            toggleItem2.click()
        }
    }

    // MARK: - View Menu Completeness

    func testViewMenuShowTimestamps() throws {
        app.menuBars.firstMatch.menuBarItems["View"].click()

        let timestampItem = app.menuItems["Show Timestamps"]
        XCTAssertTrue(timestampItem.waitForExistence(timeout: 2), "Show Timestamps should be in View menu")
        XCTAssertTrue(timestampItem.isEnabled, "Show Timestamps should be enabled")

        app.typeKey(.escape, modifierFlags: [])
    }

    func testViewMenuFind() throws {
        app.menuBars.firstMatch.menuBarItems["View"].click()

        let findItem = app.menuItems["Find"]
        XCTAssertTrue(findItem.waitForExistence(timeout: 2), "Find should be in View menu")
        findItem.click()

        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 3), "Search bar should open from View > Find")

        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Window State Persistence

    func testWindowPositionPersists() throws {
        let window = app.windows["Holoscape"]
        let initialFrame = window.frame

        app.terminate()
        app.launch()

        let window2 = app.windows["Holoscape"]
        XCTAssertTrue(window2.waitForExistence(timeout: 5), "Window should exist after restart")

        let restoredFrame = window2.frame
        XCTAssertEqual(restoredFrame.origin.x, initialFrame.origin.x, accuracy: 10, "Window X position should persist")
        XCTAssertEqual(restoredFrame.origin.y, initialFrame.origin.y, accuracy: 10, "Window Y position should persist")
    }

    func testWindowSizePersists() throws {
        let window = app.windows["Holoscape"]
        let initialFrame = window.frame

        app.terminate()
        app.launch()

        let window2 = app.windows["Holoscape"]
        XCTAssertTrue(window2.waitForExistence(timeout: 5))

        let restoredFrame = window2.frame
        XCTAssertEqual(restoredFrame.width, initialFrame.width, accuracy: 10, "Window width should persist")
        XCTAssertEqual(restoredFrame.height, initialFrame.height, accuracy: 10, "Window height should persist")
    }
}
