import XCTest

/// Shared base class for all Holoscape UI tests.
/// Provides common setup/teardown, channel creation helpers, and settings helpers.
@MainActor
class HoloscapeUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launch()

        // Wait for the app to fully initialize before proceeding.
        // Without this, ~57% of tests fail with "Application has not loaded accessibility"
        // because applicationDidFinishLaunching hasn't completed yet.
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "App window should appear after launch")
        let sidebar = window.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'sidebar-'")
        ).firstMatch
        _ = sidebar.waitForExistence(timeout: 10)
    }

    override func tearDownWithError() throws {
        Self.apiReady = false
        app.terminate()
    }

    // MARK: - Channel Helpers

    /// Create a channel via File > New Channel dialog.
    /// Valid types: "Shell", "Agent (OAuth)", "Agent (API Key)", "Group Chat", "Bridge"
    func createChannel(type: String) {
        app.menuBars.firstMatch.menuBarItems["File"].click()
        let newChannelItem = app.menuItems["New Channel"]
        XCTAssertTrue(newChannelItem.waitForExistence(timeout: 2), "New Channel menu item should exist")
        newChannelItem.click()
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 3), "New Channel dialog should appear")
        let button = dialog.buttons[type]
        XCTAssertTrue(button.waitForExistence(timeout: 2), "\(type) button should exist in dialog")
        button.click()
    }

    /// Find a sidebar entry by partial identifier match (CONTAINS).
    func sidebarEntry(_ label: String) -> XCUIElement {
        let window = app.windows["Holoscape"]
        return window.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "sidebar-\(label)")).firstMatch
    }

    /// Click a sidebar entry, handling the case where it exists but isn't hittable
    /// (e.g., partially off-screen or needs scrolling into view).
    func clickSidebarEntry(_ label: String, timeout: TimeInterval = 3) {
        let entry = sidebarEntry(label)
        XCTAssertTrue(entry.waitForExistence(timeout: timeout), "\(label) sidebar entry should exist")
        if entry.isHittable {
            entry.click()
        } else {
            // Force click via coordinate — element exists but isn't hittable
            entry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
    }

    /// Find a sidebar entry by exact identifier match.
    func sidebarEntryExact(_ label: String) -> XCUIElement {
        let window = app.windows["Holoscape"]
        return window.buttons.matching(NSPredicate(format: "identifier == %@", "sidebar-\(label)")).firstMatch
    }

    /// Find a pinned sidebar entry by label. Queries accessibility title for pin emoji.
    func pinnedSidebarEntry(_ label: String) -> XCUIElement {
        let window = app.windows["Holoscape"]
        return window.buttons.matching(NSPredicate(
            format: "title CONTAINS %@ AND title CONTAINS %@",
            "\u{1F4CC}", label
        )).firstMatch
    }

    /// Find the first sidebar entry (whatever the default channel is called).
    func firstSidebarEntry() -> XCUIElement {
        let window = app.windows["Holoscape"]
        return window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'")).firstMatch
    }

    /// Count sidebar entries.
    func sidebarEntryCount() -> Int {
        let window = app.windows["Holoscape"]
        return window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'")).count
    }

    /// Find a tab bar entry by partial identifier match.
    func tabEntry(_ identifier: String) -> XCUIElement {
        let window = app.windows["Holoscape"]
        return window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tab-\(identifier)")).firstMatch
    }

    // MARK: - Settings Helpers

    func openSettings() {
        app.typeKey(",", modifierFlags: .command)
        let settingsWindow = app.windows["Appearance Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 3), "Settings window should open")
    }

    func closeSettings() {
        let settingsWindow = app.windows["Appearance Settings"]
        if settingsWindow.exists {
            settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
        }
    }

    /// Get the settings window's theme popup by accessibility identifier.
    func themePopup() -> XCUIElement {
        return app.windows["Appearance Settings"].popUpButtons["theme-popup"]
    }

    /// Get the settings window's font family popup by accessibility identifier.
    func fontFamilyPopup() -> XCUIElement {
        return app.windows["Appearance Settings"].popUpButtons["font-family-popup"]
    }

    /// Get the settings window's font size field by accessibility identifier.
    func fontSizeField() -> XCUIElement {
        return app.windows["Appearance Settings"].textFields["font-size-field"]
    }

    /// Get the settings window's transparency slider by accessibility identifier.
    func transparencySlider() -> XCUIElement {
        return app.windows["Appearance Settings"].sliders["transparency-slider"]
    }

    /// Select a theme from the settings theme popup.
    func selectTheme(_ name: String) {
        let popup = themePopup()
        guard popup.waitForExistence(timeout: 2) else {
            XCTFail("Theme popup not found — cannot select '\(name)'")
            return
        }
        popup.click()
        let themeItem = app.menuItems[name]
        if themeItem.waitForExistence(timeout: 1) {
            themeItem.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
            XCTFail("Theme '\(name)' not found in theme popup")
        }
    }

    /// Select a font from the settings font family popup.
    func selectFont(_ name: String) {
        let popup = fontFamilyPopup()
        guard popup.waitForExistence(timeout: 2) else {
            XCTFail("Font popup not found — cannot select '\(name)'")
            return
        }
        popup.click()
        let fontItem = app.menuItems[name]
        if fontItem.waitForExistence(timeout: 1) {
            fontItem.click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
            XCTFail("Font '\(name)' not found in font popup — may not be installed")
        }
    }

    /// Set font size in the settings text field.
    func setFontSize(_ size: String) {
        let field = fontSizeField()
        guard field.waitForExistence(timeout: 2) else {
            XCTFail("Font size field not found in settings")
            return
        }
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(size)
        field.typeKey(.return, modifierFlags: [])
    }

    /// Read current theme popup value.
    func currentThemeValue() -> String {
        let popup = themePopup()
        guard popup.waitForExistence(timeout: 2) else {
            XCTFail("Theme popup not found")
            return ""
        }
        return popup.value as? String ?? ""
    }

    /// Read current font family popup value.
    func currentFontValue() -> String {
        let popup = fontFamilyPopup()
        guard popup.waitForExistence(timeout: 2) else {
            XCTFail("Font popup not found")
            return ""
        }
        return popup.value as? String ?? ""
    }

    /// Read current font size field value.
    func currentFontSizeValue() -> String {
        let field = fontSizeField()
        guard field.waitForExistence(timeout: 2) else {
            XCTFail("Font size field not found")
            return ""
        }
        return field.value as? String ?? ""
    }

    // MARK: - Search Helpers

    func openSearch() {
        app.typeKey("f", modifierFlags: .command)
        let searchBar = app.toolbars["Search Bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 2), "Search bar should open")
    }

    func closeSearch() {
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Read the match count label text from the search bar, waiting for results.
    func searchMatchCountText(timeout: TimeInterval = 3) -> String? {
        let searchBar = app.toolbars["Search Bar"]
        let label = searchBar.staticTexts["search-match-count"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if label.exists, !label.label.isEmpty { return label.label }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return label.exists ? label.label : nil
    }

    // MARK: - HTTP API Helpers

    private nonisolated(unsafe) static let apiBase = "http://127.0.0.1:7865"
    private nonisolated(unsafe) static var apiReady = false

    /// Wait for the API server to start responding.
    private nonisolated func ensureAPIReady() {
        guard !Self.apiReady else { return }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let url = URL(string: Self.apiBase + "/channels")!
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 2
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            URLSession.shared.dataTask(with: req) { _, response, _ in
                if let http = response as? HTTPURLResponse, http.statusCode == 200 { ok = true }
                sem.signal()
            }.resume()
            sem.wait()
            if ok { Self.apiReady = true; return }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// Synchronous HTTP request to the Holoscape API server.
    /// Marked nonisolated to avoid blocking the MainActor — the API server
    /// dispatches responses via Task { @MainActor }, which deadlocks if
    /// the caller is also blocking the main actor with semaphore.wait().
    @discardableResult
    nonisolated func apiRequest(_ method: String, path: String, body: [String: Any]? = nil) throws -> (Data, Int) {
        ensureAPIReady()
        let url = URL(string: Self.apiBase + path)!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseCode: Int?
        var responseError: Error?

        URLSession.shared.dataTask(with: request) { data, response, error in
            responseData = data
            responseCode = (response as? HTTPURLResponse)?.statusCode
            responseError = error
            semaphore.signal()
        }.resume()

        semaphore.wait()
        if let responseError { throw responseError }
        return (responseData ?? Data(), responseCode ?? 0)
    }

    /// List all channels via GET /channels.
    nonisolated func apiListChannels() throws -> [[String: Any]] {
        let (data, _) = try apiRequest("GET", path: "/channels")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            XCTFail("Failed to decode channels JSON array")
            return []
        }
        return json
    }

    /// Create a channel via POST /channels.
    @discardableResult
    nonisolated func apiCreateChannel(type: String = "shell", dir: String? = nil, label: String? = nil, cmd: String? = nil) throws -> (Data, Int) {
        var body: [String: Any] = ["type": type]
        if let dir { body["dir"] = dir }
        if let label { body["label"] = label }
        if let cmd { body["cmd"] = cmd }
        return try apiRequest("POST", path: "/channels", body: body)
    }

    /// Read output lines from a channel via GET /channels/{label}/output.
    nonisolated func apiReadOutput(label: String, lines: Int = 50) throws -> [String] {
        let encoded = label.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? label
        let (data, _) = try apiRequest("GET", path: "/channels/\(encoded)/output?lines=\(lines)")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outputLines = json["lines"] as? [String] else {
            return []
        }
        return outputLines
    }

    /// Send input to a channel via POST /channels/{label}/input.
    nonisolated func apiSendInput(label: String, text: String) throws {
        let encoded = label.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? label
        try apiRequest("POST", path: "/channels/\(encoded)/input", body: ["text": text])
    }

    /// Switch to a channel via POST /channels/{label}/switch.
    nonisolated func apiSwitchChannel(label: String) throws {
        let encoded = label.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? label
        try apiRequest("POST", path: "/channels/\(encoded)/switch")
    }

    /// Delete a channel via DELETE /channels/{label}.
    nonisolated func apiDeleteChannel(label: String) throws {
        let encoded = label.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? label
        try apiRequest("DELETE", path: "/channels/\(encoded)")
    }

    /// Send a notification via POST /notify.
    @discardableResult
    nonisolated func apiNotify(type: String, cwd: String) throws -> (Data, Int) {
        return try apiRequest("POST", path: "/notify", body: ["type": type, "cwd": cwd])
    }

    /// Poll channel output until it contains the expected text, or timeout.
    nonisolated func waitForAPIOutput(label: String, containing text: String, timeout: TimeInterval = 10) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let lines = try apiReadOutput(label: label)
            if lines.contains(where: { $0.contains(text) }) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// Get the terminal view element by accessibility identifier.
    /// HoloscapeTerminalView uses role .textArea, so XCTest classifies it under textViews.
    func terminalView() -> XCUIElement {
        let window = app.windows["Holoscape"]
        // Try textViews first (matches .textArea role), fall back to otherElements
        let tv = window.textViews["terminal-view"]
        if tv.exists { return tv }
        return window.otherElements["terminal-view"]
    }

    /// Assert the active channel is responsive by verifying the terminal view exists.
    /// Use this instead of checking for "input-box" — shell/PTY channels type directly
    /// into the terminal and have no separate input box. The input box is only visible
    /// for non-PTY channels (e.g., Group Chat, Bridge).
    func assertActiveChannelResponsive(timeout: TimeInterval = 3, message: String = "Active channel should be responsive") {
        let terminal = terminalView()
        let inputBox = app.textViews["input-box"]
        let isResponsive = terminal.waitForExistence(timeout: timeout) || inputBox.waitForExistence(timeout: 1)
        XCTAssertTrue(isResponsive, message)
    }

    /// Restart the app cleanly — terminate, wait for not-running state, then relaunch.
    /// Use this instead of bare terminate()/launch() pairs to avoid timing races where
    /// the persistence layer hasn't finished flushing before the process exits.
    func restartApp() {
        app.terminate()
        let notRunning = NSPredicate(format: "state == %d", XCUIApplication.State.notRunning.rawValue)
        expectation(for: notRunning, evaluatedWith: app, handler: nil)
        waitForExpectations(timeout: 5)
        app.launch()

        let window = app.windows["Holoscape"]
        _ = window.waitForExistence(timeout: 10)
        let sidebar = window.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'sidebar-'")
        ).firstMatch
        _ = sidebar.waitForExistence(timeout: 10)
    }

    /// Open a URL using /usr/bin/open (for URL scheme tests).
    func openURL(_ urlString: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [urlString]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Dependency Checks

    /// Skip test if the Claude CLI binary is not installed.
    func skipUnlessClaudeCLIInstalled() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: "/opt/homebrew/bin/claude"),
            "Claude CLI not installed at /opt/homebrew/bin/claude"
        )
    }

    /// Skip test if a font family is not available on this system.
    func skipUnlessFontAvailable(_ fontName: String) throws {
        let available = NSFontManager.shared.availableFontFamilies.contains(fontName)
        try XCTSkipUnless(available, "Font '\(fontName)' not installed on this system")
    }
}
