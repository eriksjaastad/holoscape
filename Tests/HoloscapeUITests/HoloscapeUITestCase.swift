import XCTest

/// Shared base class for all Holoscape UI tests.
/// Provides common setup/teardown, channel creation helpers, and settings helpers.
@MainActor
class HoloscapeUITestCase: XCTestCase {
    var app: XCUIApplication!

    /// Per-test random port eliminates the API timing race between test runs.
    /// Each test gets its own port so there's no contention with a dying app.
    private var apiPort: UInt16 = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Pick a random port in the ephemeral range for this test
        apiPort = UInt16.random(in: 49152...60999)
        Self.currentAPIBase = "http://127.0.0.1:\(apiPort)"
        app = XCUIApplication()
        app.launchArguments.append("--ui-testing")
        app.launchArguments += ["--api-port", "\(apiPort)"]
        app.launch()

        // Wait for the app to fully initialize before proceeding.
        let window = app.windows["Holoscape"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "App window should appear after launch")
        let sidebar = window.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'sidebar-'")
        ).firstMatch
        _ = sidebar.waitForExistence(timeout: 10)
    }

    override func tearDownWithError() throws {
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

    /// Find a sidebar entry by index (0-based). Use when labels are dynamic (OSC 7 updates).
    func sidebarEntryAt(_ index: Int) -> XCUIElement {
        let window = app.windows["Holoscape"]
        return window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'")).element(boundBy: index)
    }

    /// Wait for sidebar to have at least N entries, then return the last one.
    func waitForNewSidebarEntry(expectedCount: Int, timeout: TimeInterval = 5) -> XCUIElement {
        let window = app.windows["Holoscape"]
        let entries = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar-'"))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if entries.count >= expectedCount {
                return entries.element(boundBy: expectedCount - 1)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return entries.element(boundBy: expectedCount - 1)
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

    func searchField(timeout: TimeInterval = 2) -> XCUIElement {
        let searchBar = app.toolbars["Search Bar"]
        let candidates = [
            searchBar.searchFields["search-field"],
            searchBar.textFields["search-field"],
            searchBar.searchFields.firstMatch,
            searchBar.textFields.firstMatch,
            searchBar.descendants(matching: .any)["search-field"],
        ]
        for field in candidates where field.waitForExistence(timeout: timeout) {
            return field
        }
        return candidates[0]
    }

    /// Read the match count label text from the search bar, waiting for results.
    /// Needs sufficient timeout for: 150ms search debounce + terminal buffer scan + UI update.
    func searchMatchCountText(timeout: TimeInterval = 5) -> String? {
        let searchBar = app.toolbars["Search Bar"]
        let label = searchBar.descendants(matching: .any)["search-match-count"]
        let deadline = Date().addingTimeInterval(timeout)
        var latestText: String?
        while Date() < deadline {
            if label.exists {
                let text = (label.value as? String) ?? label.label
                if !text.isEmpty {
                    latestText = text
                    if text.contains(" of ") { return text }
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        if let latestText { return latestText }
        guard label.exists else { return nil }
        let text = (label.value as? String) ?? label.label
        return text.isEmpty ? nil : text
    }

    // MARK: - HTTP API Helpers

    /// Per-test API base URL — set in setUp to match the random port.
    /// Internal so subclasses that override setUpWithError can set it.
    nonisolated(unsafe) static var currentAPIBase = "http://127.0.0.1:7865"

    /// Background queue for API calls.
    private static let apiQueue = DispatchQueue(label: "holoscape.test.api", qos: .userInitiated)

    /// Wait for the API server to start responding on this test's unique port.
    /// Spins the RunLoop so the MainActor can process the server's `Task { @MainActor }`
    /// response dispatch. A semaphore.wait() would deadlock because this method
    /// (though nonisolated) runs on the main thread when called from @MainActor test code.
    private nonisolated func ensureAPIReady() {
        var ready = false
        var finished = false
        Self.apiQueue.async {
            defer { finished = true }
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline && !ready {
                let url = URL(string: Self.currentAPIBase + "/channels")!
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
                if ok { ready = true; return }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        // Spin RunLoop so MainActor Tasks can execute (server dispatches via Task { @MainActor }).
        // Outer wall-clock deadline prevents an infinite spin if the background probe exits
        // without setting `ready` (e.g. API server never came up).
        let outerDeadline = Date().addingTimeInterval(12)
        while !ready && !finished && Date() < outerDeadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        if !ready {
            XCTFail("API server did not become ready within 10s at \(Self.currentAPIBase)")
        }
    }

    /// Synchronous HTTP request to the Holoscape API server.
    /// The server processes requests via `Task { @MainActor }`, so we MUST NOT
    /// block the MainActor thread while waiting for a response. Although this
    /// method is `nonisolated`, Swift calls it synchronously on the main thread
    /// when invoked from @MainActor test methods. We spin the RunLoop instead
    /// of using semaphore.wait() so the MainActor can process the server's
    /// response Tasks.
    @discardableResult
    nonisolated func apiRequest(_ method: String, path: String, body: [String: Any]? = nil) throws -> (Data, Int) {
        return try performAPIRequest(method, path: path, body: body, allowErrorStatus: false)
    }

    /// Variant of apiRequest that returns non-2xx responses to the caller instead
    /// of surfacing them as harness errors.
    @discardableResult
    nonisolated func apiRequestAllowingError(_ method: String, path: String, body: [String: Any]? = nil) throws -> (Data, Int) {
        return try performAPIRequest(method, path: path, body: body, allowErrorStatus: true)
    }

    @discardableResult
    private nonisolated func performAPIRequest(_ method: String, path: String, body: [String: Any]? = nil, allowErrorStatus: Bool) throws -> (Data, Int) {
        ensureAPIReady()

        var responseData: Data?
        var responseCode: Int?
        var responseError: Error?
        var completed = false

        Self.apiQueue.async {
            let url = URL(string: Self.currentAPIBase + path)!
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 15
            if let body {
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }

            let sem = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { data, response, error in
                responseData = data
                responseCode = (response as? HTTPURLResponse)?.statusCode
                responseError = error
                sem.signal()
            }.resume()
            sem.wait()
            completed = true
        }

        // Spin RunLoop so MainActor Tasks can execute while we wait
        while !completed {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        if let responseError { throw responseError }
        let code = responseCode ?? 0
        // P0: surface non-2xx server responses instead of silently returning
        // them. Previously every caller discarded the status code, masking
        // 500 "Not ready" and 404 "channel not found" as downstream UI
        // assertion failures. See docs/round-9-deep-dive.md Bucket A.
        if !allowErrorStatus && !(200...299).contains(code) {
            let body = String(data: responseData ?? Data(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "HoloscapeAPITest",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) \(method) \(path): \(body)"]
            )
        }
        return (responseData ?? Data(), code)
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

    /// Send input to a channel via POST /channels/{id}/input using a stable identifier.
    nonisolated func apiSendInput(channelRef: String, text: String) throws {
        let encoded = channelRef.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? channelRef
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
    /// Uses RunLoop spinning between polls to keep the MainActor responsive.
    nonisolated func waitForAPIOutput(label: String, containing text: String, timeout: TimeInterval = 15) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let lines = try apiReadOutput(label: label)
            if lines.contains(where: { $0.contains(text) }) {
                return true
            }
            // Spin RunLoop instead of Thread.sleep to keep MainActor responsive
            let waitUntil = Date(timeIntervalSinceNow: 0.5)
            while Date() < waitUntil {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }
        return false
    }

    nonisolated func apiReadOutput(channelRef: String, lines: Int = 50) throws -> [String] {
        let encoded = channelRef.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? channelRef
        let (data, _) = try apiRequest("GET", path: "/channels/\(encoded)/output?lines=\(lines)")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outputLines = json["lines"] as? [String] else {
            return []
        }
        return outputLines
    }

    nonisolated func waitForAPIOutput(channelRef: String, containing text: String, timeout: TimeInterval = 15) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let lines = try apiReadOutput(channelRef: channelRef)
            if lines.contains(where: { $0.contains(text) }) {
                return true
            }
            let waitUntil = Date(timeIntervalSinceNow: 0.5)
            while Date() < waitUntil {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }
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
