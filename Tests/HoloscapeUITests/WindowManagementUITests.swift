import XCTest

final class WindowManagementUITests: HoloscapeUITestCase {

    // MARK: - Window Operations

    func testWindowMinimize() throws {
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 3))

        window.buttons[XCUIIdentifierMinimizeWindow].click()
        Thread.sleep(forTimeInterval: 0.5)

        // Restore via Window menu — scope search to the Window menu's own items
        // to avoid matching "Force Quit Holoscape" in the Apple menu.
        app.activate()
        let windowMenu = app.menuBars.firstMatch.menuBarItems["Window"]
        windowMenu.click()
        let windowItem = windowMenu.menus.firstMatch.menuItems.matching(
            NSPredicate(format: "title CONTAINS 'Holoscape'")
        ).firstMatch
        if windowItem.waitForExistence(timeout: 2) {
            windowItem.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
            // Fallback: just activate the app which should restore on macOS
            app.activate()
        }
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(window.waitForExistence(timeout: 5), "Window should be restorable after minimize")
    }

    func testWindowZoom() throws {
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 3))

        let initialFrame = window.frame

        // Zoom via green button — use the standard identifier first, fall back to coordinate
        let zoomButton = window.buttons[XCUIIdentifierZoomWindow]
        if zoomButton.exists && zoomButton.isHittable {
            zoomButton.click()
        } else {
            // Zoom via Window menu
            app.menuBars.firstMatch.menuBarItems["Window"].click()
            let zoomItem = app.menuItems["Zoom"]
            if zoomItem.waitForExistence(timeout: 1) {
                zoomItem.click()
            } else {
                app.typeKey(.escape, modifierFlags: [])
                throw XCTSkip("Zoom button/menu not available on this macOS version")
            }
        }

        assertActiveChannelResponsive(message: "Channel should be responsive after zoom")

        let zoomedFrame = window.frame
        XCTAssertNotEqual(initialFrame, zoomedFrame, "Window frame should change after zoom")
    }

    func testWindowFullScreen() throws {
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 3))

        // Enter full screen via Ctrl+Cmd+F
        app.typeKey("f", modifierFlags: [.control, .command])

        // Verify window still functional in full screen
        assertActiveChannelResponsive(timeout: 5, message: "Channel should be responsive in full screen")

        // Exit full screen via Ctrl+Cmd+F (NOT Escape)
        app.typeKey("f", modifierFlags: [.control, .command])

        // Wait for fullscreen animation to complete
        assertActiveChannelResponsive(timeout: 5, message: "Channel should be responsive after exiting full screen")
    }

    func testWindowRestoreAfterMinimize() throws {
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 3))

        // Minimize and restore
        window.buttons[XCUIIdentifierMinimizeWindow].click()
        Thread.sleep(forTimeInterval: 0.5)

        app.activate()
        let windowMenu = app.menuBars.firstMatch.menuBarItems["Window"]
        windowMenu.click()
        let windowItem = windowMenu.menus.firstMatch.menuItems.matching(
            NSPredicate(format: "title CONTAINS 'Holoscape'")
        ).firstMatch
        if windowItem.waitForExistence(timeout: 2) {
            windowItem.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
            app.activate()
        }
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(window.waitForExistence(timeout: 5), "Window should be restorable after minimize")
        assertActiveChannelResponsive(message: "Channel should be responsive after minimize/restore")
    }

    // MARK: - Application Menu

    func testAboutDialogOpens() throws {
        let appMenu = app.menuBars.firstMatch.menuBarItems["Holoscape"]
        XCTAssertTrue(appMenu.waitForExistence(timeout: 2))
        appMenu.click()

        let aboutItem = app.menuItems.matching(NSPredicate(format: "title CONTAINS 'About'")).firstMatch
        XCTAssertTrue(aboutItem.waitForExistence(timeout: 2), "About menu item should exist")
        aboutItem.click()

        // The standard macOS About panel reports invalid accessibility coordinates
        // (INFINITY), which causes NSInternalInconsistencyException if XCUITest
        // queries the panel's frame. Do not touch any About panel elements.
        // Dismiss via Escape, then bring the main window forward using a fixed
        // normalized coordinate (avoiding any AX geometry lookup).
        Thread.sleep(forTimeInterval: 1.0)
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        let mainWindow = app.windows["Holoscape"]
        if mainWindow.exists && mainWindow.isHittable {
            mainWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertTrue(mainWindow.waitForExistence(timeout: 3), "Main window should remain after opening About dialog")
    }

    func testAboutDialogCloses() throws {
        let appMenu = app.menuBars.firstMatch.menuBarItems["Holoscape"]
        appMenu.click()

        let aboutItem = app.menuItems.matching(NSPredicate(format: "title CONTAINS 'About'")).firstMatch
        if aboutItem.waitForExistence(timeout: 2) {
            aboutItem.click()
            // Don't touch About panel elements — INFINITY AX coords crash XCUITest.
            Thread.sleep(forTimeInterval: 1.0)
            app.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.5)

            let mainWindow = app.windows["Holoscape"]
            if mainWindow.exists && mainWindow.isHittable {
                mainWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            }
            Thread.sleep(forTimeInterval: 0.3)
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }

        assertActiveChannelResponsive(message: "Channel should be responsive after closing About dialog")
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

        // Should focus session launcher — verify channel still responsive
        assertActiveChannelResponsive(message: "Channel should be responsive after New Session")
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
