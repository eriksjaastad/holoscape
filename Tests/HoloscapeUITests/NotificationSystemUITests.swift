import XCTest

final class NotificationSystemUITests: HoloscapeUITestCase {

    /// Override setUp to pass the suppression bypass argument for most tests.
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("--disable-notification-suppression")
        app.launch()
    }

    // MARK: - Idle Prompt (Green)

    func testIdlePromptTurnsTabGreen() throws {
        try apiCreateChannel(dir: "/tmp", label: "notify-green")
        let entry = sidebarEntry("notify-green")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))

        try apiNotify(type: "idle_prompt", cwd: "/tmp")
        Thread.sleep(forTimeInterval: 0.5)

        // Sidebar entry should have accessibility value "ready"
        let value = entry.value as? String
        XCTAssertEqual(value, "ready", "Idle prompt should set tab accessibility value to 'ready'")
    }

    // MARK: - Permission Prompt (Amber)

    func testPermissionPromptTurnsTabAmber() throws {
        try apiCreateChannel(dir: "/tmp", label: "notify-amber")
        let entry = sidebarEntry("notify-amber")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))

        try apiNotify(type: "permission_prompt", cwd: "/tmp")
        Thread.sleep(forTimeInterval: 0.5)

        let value = entry.value as? String
        XCTAssertEqual(value, "needs-approval", "Permission prompt should set tab accessibility value to 'needs-approval'")
    }

    // MARK: - Click Clears Notification

    func testClickingNotifiedTabClearsNotification() throws {
        try apiCreateChannel(dir: "/tmp", label: "notify-clear")

        // Switch away from the notify-clear channel so it's not active
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        let entry = sidebarEntry("notify-clear")
        XCTAssertTrue(entry.waitForExistence(timeout: 3))

        try apiNotify(type: "idle_prompt", cwd: "/tmp")
        Thread.sleep(forTimeInterval: 0.5)

        // Verify notification is set
        let valueBefore = entry.value as? String
        XCTAssertEqual(valueBefore, "ready")

        // Click the notified tab to switch to it
        entry.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Notification should be cleared — value should become "active"
        let valueAfter = entry.value as? String
        XCTAssertEqual(valueAfter, "active", "Clicking notified tab should clear notification state")
    }

    // MARK: - Startup Suppression

    func testStartupSuppressionBlocksNotifications() throws {
        // This test uses a FRESH launch WITHOUT the suppression bypass
        app.terminate()

        let freshApp = XCUIApplication()
        // No --disable-notification-suppression argument
        freshApp.launch()
        // Immediately send a notification (within the 10s window)
        let (data, _) = try apiNotify(type: "idle_prompt", cwd: "/tmp")

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["status"] as? String, "suppressed", "Notifications should be suppressed during startup")

        freshApp.terminate()
    }

    func testNotificationAfterSuppressionWindowWorks() throws {
        // With --disable-notification-suppression, notifications work immediately
        try apiCreateChannel(dir: "/tmp", label: "post-suppress")
        Thread.sleep(forTimeInterval: 0.5)

        let (data, _) = try apiNotify(type: "idle_prompt", cwd: "/tmp")

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["status"] as? String, "received", "Notifications should work when suppression is disabled")
    }
}
