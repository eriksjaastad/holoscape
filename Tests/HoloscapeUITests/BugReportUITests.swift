import XCTest

final class BugReportUITests: HoloscapeUITestCase {

    // MARK: - Helpers

    private func openBugReportDialog() {
        app.typeKey("b", modifierFlags: [.command, .shift])
        // The dialog is a sheet on the main window
    }

    private func firstAlertOrSheet() -> XCUIElement {
        if app.alerts.firstMatch.exists {
            return app.alerts.firstMatch
        }
        return app.sheets.firstMatch
    }

    // MARK: - Dialog Lifecycle

    func testCmdShiftBOpensBugReportDialog() throws {
        openBugReportDialog()

        let dialog = app.sheets["bug-report-dialog"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 3), "Cmd+Shift+B should open the bug report dialog")
    }

    func testHelpMenuReportBugOpensDialog() throws {
        app.menuBars.firstMatch.menuBarItems["Help"].click()
        let reportBugItem = app.menuItems["Report Bug"]
        XCTAssertTrue(reportBugItem.waitForExistence(timeout: 2), "Report Bug menu item should exist under Help")
        reportBugItem.click()

        let dialog = app.sheets["bug-report-dialog"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 3), "Help > Report Bug should open the bug report dialog")
    }

    func testCancelDismissesBugReportDialog() throws {
        openBugReportDialog()

        let dialog = app.sheets["bug-report-dialog"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 3), "Bug report dialog should appear")

        // Dismiss via Escape
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertFalse(dialog.waitForExistence(timeout: 2), "Bug report dialog should be dismissed after pressing Escape")

        // Verify main window is still functional
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should remain functional after dismissing dialog")
    }

    func testSubmitWithEmptyDescriptionShowsValidation() throws {
        openBugReportDialog()

        let dialog = app.sheets["bug-report-dialog"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 3), "Bug report dialog should appear")

        let submitButton = app.buttons["bug-submit-button"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 2), "Submit button should exist")
        submitButton.click()

        // Validation alert should appear
        let alert = firstAlertOrSheet()
        XCTAssertTrue(alert.waitForExistence(timeout: 3), "Submitting with empty description should show a validation alert")

        // Dismiss the alert
        let okButton = alert.buttons.firstMatch
        if okButton.waitForExistence(timeout: 1) {
            okButton.click()
        }
    }

    // MARK: - Dialog Contents

    func testBugReportDialogHasDescriptionField() throws {
        openBugReportDialog()

        let dialog = app.sheets["bug-report-dialog"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 3), "Bug report dialog should appear")

        let descriptionField = app.textViews["bug-description-field"]
        if !descriptionField.exists {
            // Also check textFields in case it's a single-line field
            let textField = app.textFields["bug-description-field"]
            XCTAssertTrue(textField.waitForExistence(timeout: 2), "Bug description field should exist in dialog")
        } else {
            XCTAssertTrue(descriptionField.exists, "Bug description field should exist in dialog")
        }
    }

    func testBugReportDialogHasContextView() throws {
        openBugReportDialog()

        let dialog = app.sheets["bug-report-dialog"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 3), "Bug report dialog should appear")

        // Query broadly for the context view element by accessibility identifier
        let contextView = app.descendants(matching: .any)["bug-context-view"]
        XCTAssertTrue(contextView.waitForExistence(timeout: 2), "Bug context view should exist in dialog")
    }

    func testBugReportDialogHasScreenshotButton() throws {
        openBugReportDialog()

        let dialog = app.sheets["bug-report-dialog"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 3), "Bug report dialog should appear")

        let screenshotButton = app.buttons["bug-screenshot-button"]
        XCTAssertTrue(screenshotButton.waitForExistence(timeout: 2), "Screenshot button should exist in dialog")
        XCTAssertTrue(screenshotButton.isHittable, "Screenshot button should be hittable")
    }

    func testBugReportDialogHasSubmitButton() throws {
        openBugReportDialog()

        let dialog = app.sheets["bug-report-dialog"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 3), "Bug report dialog should appear")

        let submitButton = app.buttons["bug-submit-button"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 2), "Submit button should exist in dialog")
    }

    // MARK: - Screenshot

    func testScreenshotButtonChangesAfterClick() throws {
        openBugReportDialog()

        let dialog = app.sheets["bug-report-dialog"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 3), "Bug report dialog should appear")

        let screenshotButton = app.buttons["bug-screenshot-button"]
        XCTAssertTrue(screenshotButton.waitForExistence(timeout: 2), "Screenshot button should exist")

        screenshotButton.click()

        // After clicking, the button title should change to indicate screenshot was taken
        let titleChanged = NSPredicate(format: "label == 'Screenshot Attached'")
        let result = expectation(for: titleChanged, evaluatedWith: screenshotButton, handler: nil)
        wait(for: [result], timeout: 5)

        XCTAssertEqual(screenshotButton.label, "Screenshot Attached", "Screenshot button title should change to 'Screenshot Attached' after click")
        XCTAssertFalse(screenshotButton.isEnabled, "Screenshot button should be disabled after attaching screenshot")
    }

    // MARK: - Input

    func testDescriptionFieldAcceptsText() throws {
        openBugReportDialog()

        let dialog = app.sheets["bug-report-dialog"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 3), "Bug report dialog should appear")

        let descriptionField = app.textViews["bug-description-field"]
        XCTAssertTrue(descriptionField.waitForExistence(timeout: 2), "Bug description field should exist")

        descriptionField.click()
        descriptionField.typeText("This is a test bug report")

        let value = descriptionField.value as? String ?? ""
        XCTAssertTrue(value.contains("This is a test bug report"), "Description field should contain typed text")
    }

    func testDescriptionFieldAcceptsMultipleLines() throws {
        openBugReportDialog()

        let dialog = app.sheets["bug-report-dialog"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 3), "Bug report dialog should appear")

        let descriptionField = app.textViews["bug-description-field"]
        XCTAssertTrue(descriptionField.waitForExistence(timeout: 2), "Bug description field should exist")

        descriptionField.click()
        descriptionField.typeText("First line of bug report")
        descriptionField.typeKey(.return, modifierFlags: [])
        descriptionField.typeText("Second line with more details")

        let value = descriptionField.value as? String ?? ""
        XCTAssertTrue(value.contains("First line of bug report"), "Description should contain first line")
        XCTAssertTrue(value.contains("Second line with more details"), "Description should contain second line")
    }

    // MARK: - Submit Path

    func testSubmitWithDescriptionShowsConfirmation() throws {
        openBugReportDialog()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3), "Bug report sheet should appear")

        // Type description
        let descField = sheet.textViews["bug-description-field"]
        if descField.waitForExistence(timeout: 2) {
            descField.click()
            descField.typeText("Test bug report from UI test")
        } else {
            let textField = sheet.textFields["bug-description-field"]
            XCTAssertTrue(textField.waitForExistence(timeout: 2), "Description field should exist")
            textField.click()
            textField.typeText("Test bug report from UI test")
        }

        // Submit
        let submitButton = sheet.buttons["bug-submit-button"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 2), "Submit button should exist")
        submitButton.click()

        // Should see confirmation alert (success or network failure — either means path executed)
        let alert = firstAlertOrSheet()
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Confirmation alert should appear after submission")
        // Dismiss the confirmation
        let okButton = alert.buttons.firstMatch
        if okButton.waitForExistence(timeout: 1) {
            okButton.click()
        }
    }
}
