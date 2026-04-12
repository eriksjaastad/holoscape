import XCTest

final class NotificationSystemUITests: HoloscapeUITestCase {

    private func collapseSidebarToShowTopTabs() {
        app.typeKey("s", modifierFlags: [.command, .shift])
        let window = app.windows["Holoscape"]
        let anyTab = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab-'")).firstMatch
        _ = anyTab.waitForExistence(timeout: 3)
    }

    /// Override setUp to pass the suppression bypass argument for most tests.
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launchArguments.append("--disable-notification-suppression")
        let port = UInt16.random(in: 49152...60999)
        Self.currentAPIBase = "http://127.0.0.1:\(port)"
        app.launchArguments += ["--api-port", "\(port)"]
        app.launch()

        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "App window should appear after launch")
        XCTAssertTrue(ensureSidebarVisible(), "Sidebar should be visible after launch")
    }

    // MARK: - Idle Prompt (Green)

    /// Notification matching works by comparing the cwd's last path component against
    /// the channel's displayLabel (see resolveChannelByCwd in HoloscapeAPIServer).
    /// So the cwd path must end with a component that matches the channel label exactly.
    /// Example: label "notify-green" + cwd "/tmp/notify-green" → match.

    func testIdlePromptTurnsTabGreen() throws {
        try apiCreateChannel(dir: "/tmp", label: "notify-green")
        let entry = sidebarEntry("notify-green")
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(entry.identifier.contains("sidebar-notify-green") || entry.label.contains("notify-green"))

        // cwd last component must match label for resolveChannelByCwd
        try apiNotify(type: "idle_prompt", cwd: "/tmp/notify-green")
        Thread.sleep(forTimeInterval: 0.5)

        // Sidebar entry should have accessibility value "ready"
        let value = entry.value as? String
        XCTAssertEqual(value, "ready", "Idle prompt should set tab accessibility value to 'ready'")
    }

    // MARK: - Permission Prompt (Amber)

    func testPermissionPromptTurnsTabAmber() throws {
        try apiCreateChannel(dir: "/tmp", label: "notify-amber")
        let entry = sidebarEntry("notify-amber")
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(entry.identifier.contains("sidebar-notify-amber") || entry.label.contains("notify-amber"))

        try apiNotify(type: "permission_prompt", cwd: "/tmp/notify-amber")
        Thread.sleep(forTimeInterval: 0.5)

        let value = entry.value as? String
        XCTAssertEqual(value, "needs-approval", "Permission prompt should set tab accessibility value to 'needs-approval'")
    }

    func testIdlePromptTurnsTopTabReady() throws {
        try apiCreateChannel(dir: "/tmp", label: "notify-top-ready")
        let entry = sidebarEntry("notify-top-ready")
        XCTAssertTrue(entry.waitForExistence(timeout: 5))

        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        try apiNotify(type: "idle_prompt", cwd: "/tmp/notify-top-ready")
        Thread.sleep(forTimeInterval: 0.5)

        collapseSidebarToShowTopTabs()
        let tab = tabEntry("notify-top-ready")
        XCTAssertTrue(tab.waitForExistence(timeout: 3), "Top tab should exist for notified channel")
        XCTAssertEqual(tab.value as? String, "ready", "Idle prompt should set top tab accessibility value to 'ready'")
    }

    // MARK: - Click Clears Notification

    func testClickingNotifiedTabClearsNotification() throws {
        try apiCreateChannel(dir: "/tmp", label: "notify-clear")
        let entry = sidebarEntry("notify-clear")
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(entry.identifier.contains("sidebar-notify-clear") || entry.label.contains("notify-clear"))

        // Switch away from the notify-clear channel so it's not active
        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        try apiNotify(type: "idle_prompt", cwd: "/tmp/notify-clear")
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

    func testClickingNotifiedTopTabClearsNotification() throws {
        try apiCreateChannel(dir: "/tmp", label: "notify-top-clear")
        let entry = sidebarEntry("notify-top-clear")
        XCTAssertTrue(entry.waitForExistence(timeout: 5))

        app.typeKey("1", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        try apiNotify(type: "permission_prompt", cwd: "/tmp/notify-top-clear")
        Thread.sleep(forTimeInterval: 0.5)

        collapseSidebarToShowTopTabs()
        let tab = tabEntry("notify-top-clear")
        XCTAssertTrue(tab.waitForExistence(timeout: 3), "Top tab should exist for notified channel")
        XCTAssertEqual(tab.value as? String, "needs-approval")

        tab.click()
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertEqual(tab.value as? String, "active", "Clicking notified top tab should clear notification state")
    }

    // MARK: - Startup Suppression

    func testStartupSuppressionBlocksNotifications() throws {
        // This test uses a FRESH launch WITHOUT the suppression bypass
        app.terminate()
        let notRunning = NSPredicate(format: "state == %d", XCUIApplication.State.notRunning.rawValue)
        expectation(for: notRunning, evaluatedWith: app, handler: nil)
        waitForExpectations(timeout: 5)

        let freshApp = XCUIApplication()
        let port = UInt16.random(in: 49152...60999)
        Self.currentAPIBase = "http://127.0.0.1:\(port)"
        freshApp.launchArguments.append("--ui-testing")
        freshApp.launchArguments += ["--api-port", "\(port)"]
        // No --disable-notification-suppression argument
        freshApp.launch()
        // Immediately send a notification (within the 10s window)
        let (data, _) = try apiNotify(type: "idle_prompt", cwd: "/tmp/notify-suppressed")

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["status"] as? String, "suppressed", "Notifications should be suppressed during startup")

        freshApp.terminate()
    }

    func testNotificationAfterSuppressionWindowWorks() throws {
        // With --disable-notification-suppression, notifications work immediately
        try apiCreateChannel(dir: "/tmp", label: "post-suppress")
        Thread.sleep(forTimeInterval: 0.5)

        let (data, _) = try apiNotify(type: "idle_prompt", cwd: "/tmp/post-suppress")

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["status"] as? String, "received", "Notifications should work when suppression is disabled")
    }
}
