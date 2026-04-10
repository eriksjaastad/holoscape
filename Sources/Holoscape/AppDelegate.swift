import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, AppearanceSettingsDelegate {
    private var windowController: MainWindowController?
    private let configService = ConfigService()
    private let crashScanner = CrashReportScanner()
    private let bugReportService = BugReportService()
    private var notificationService: NotificationService?
    private var channelManagerRef: ChannelManager?
    private var settingsWindowController: AppearanceSettingsWindowController?
    private var apiServer: HoloscapeAPIServer?

    private var isUITesting: Bool {
        CommandLine.arguments.contains("--ui-testing")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure app activates as a foreground GUI application
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Build menu bar
        setupMenuBar()

        // Load config and apply appearance
        let config = configService.load()

        // Create channel manager and window
        let channelManager = ChannelManager(configService: configService)
        self.channelManagerRef = channelManager
        windowController = MainWindowController(channelManager: channelManager, configService: configService)

        if !isUITesting {
            // Set up session profile manager
            let discoveryService = ProjectDiscoveryService(configService: configService)
            let profileManager = SessionProfileManager(configService: configService, discoveryService: discoveryService)
            windowController?.setProfileManager(profileManager)

            // Set up notifications (deferred to avoid TCC prompt on startup)
            notificationService = NotificationService(configService: configService)
            notificationService?.channelSwitchDelegate = windowController
            windowController?.setNotificationService(notificationService!)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.notificationService?.requestAuthorization()
            }
        }

        // Start API server for MCP integration
        if let wc = windowController {
            apiServer = HoloscapeAPIServer(channelManager: channelManager, windowController: wc)
            apiServer?.start()
            wc.apiServer = apiServer
        }

        // Apply appearance
        applyAppearance(config.appearance)

        let shouldRestore = !isUITesting || CommandLine.arguments.contains("--restore-channels")
        if shouldRestore {
            // Restore channels from saved state
            channelManager.restoreState { [weak self] metadata in
                guard let self, let controller = self.createChannelFromMetadata(metadata) else { return nil }
                controller.delegate = self.windowController
                return controller
            }
        }

        // If no channels restored, create a default shell
        if channelManager.count == 0 {
            let channel = channelManager.createChannel(
                type: .shell,
                role: "Shell",
                workingDirectory: nil
            ) { id, _, _, instanceNum, _ in
                ShellChannelController(id: id, instanceNumber: instanceNum, workingDirectory: nil)
            }
            channel.activate()
            windowController?.switchToChannel(channel.channelId)
        } else if let first = channelManager.allChannels().first {
            windowController?.switchToChannel(first.channelId)
        }

        windowController?.refreshAllTabs()

        // Show window — maximize during UI testing to ensure all sidebar entries are visible
        if isUITesting, let window = windowController?.window, let screen = NSScreen.main {
            window.setFrame(screen.visibleFrame, display: true)
        }
        windowController?.window.makeKeyAndOrderFront(nil)

        if !isUITesting {
            // Retry any pending reports from previous failed submissions
            bugReportService.retryPendingReports()

            // Check for crashes on previous launch
            checkForCrashes(lastLaunch: config.lastLaunchTimestamp)

            // Update launch timestamp
            var updatedConfig = config
            updatedConfig.lastLaunchTimestamp = Date()
            configService.save(updatedConfig)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleURL(url)
        }
    }

    private func handleURL(_ url: URL) {
        guard url.scheme == "holoscape" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let params = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        switch url.host {
        case "new-channel":
            let typeStr = params["type"] ?? "shell"
            let dir = params["dir"]
            let label = params["label"]
            let cmd = params["cmd"]
            windowController?.openChannel(type: typeStr, directory: dir, label: label, command: cmd)
        default:
            NSLog("Holoscape URL: unknown host '\(url.host ?? "")'")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        apiServer?.stop()
        windowController?.channelManager.saveState()
        windowController?.historyBuffer.stopPeriodicFlush()
        windowController?.historyBuffer.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func appearanceSettingsDidChange(_ settings: AppearanceConfig) {
        windowController?.recordAppearanceChange(settings)
        applyAppearance(settings)
    }

    @objc func openSettings() {
        let config = configService.load()
        let controller = AppearanceSettingsWindowController(config: config.appearance, configService: configService)
        controller.settingsDelegate = self
        controller.showWindow(nil)
        controller.window?.center()
        settingsWindowController = controller  // retain
    }

    @objc func showBugReportDialog() {
        windowController?.showBugReportDialog()
    }

    // MARK: - Private

    private func createChannelFromMetadata(_ metadata: ChannelMetadata) -> (any ChannelController)? {
        switch metadata.type {
        case .shell:
            let defaultPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("projects").path
            var rawDir = metadata.workingDirectory ?? defaultPath
            // OSC 7 saves file:// URLs — strip to plain path
            if let url = URL(string: rawDir), url.scheme == "file" {
                rawDir = url.path
            }
            let dir = rawDir
            // Restore the saved display label; fall back to directory name
            let label = metadata.role
            let controller = ShellChannelController(
                id: metadata.id,
                instanceNumber: metadata.instanceNumber,
                label: label,
                workingDirectory: dir
            )
            controller.activate()
            return controller
        case .agentDirect:
            let dir = metadata.workingDirectory.map { URL(fileURLWithPath: $0) }
            let controller = AgentChannelController(
                id: metadata.id,
                authType: .oauth,
                workingDirectory: dir,
                userLabel: metadata.role,
                instanceNumber: metadata.instanceNumber
            )
            controller.activate()
            return controller
        case .agentAPI:
            let dir = metadata.workingDirectory.map { URL(fileURLWithPath: $0) }
            let controller = AgentChannelController(
                id: metadata.id,
                authType: .apiKey(""),  // TODO: retrieve from secure storage
                workingDirectory: dir,
                userLabel: metadata.role,
                instanceNumber: metadata.instanceNumber
            )
            // Don't auto-activate without a valid key
            return controller
        case .groupChat:
            // Load chat config
            let envPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/agent-chat.env")
            var apiURL = ""
            var apiKey = ""
            if let content = try? String(contentsOf: envPath, encoding: .utf8) {
                for line in content.components(separatedBy: "\n") {
                    if line.hasPrefix("AGENT_CHAT_URL=") {
                        apiURL = String(line.dropFirst("AGENT_CHAT_URL=".count))
                    } else if line.hasPrefix("AGENT_CHAT_API_KEY=") {
                        apiKey = String(line.dropFirst("AGENT_CHAT_API_KEY=".count))
                    }
                }
            }
            guard !apiURL.isEmpty, !apiKey.isEmpty else { return nil }
            let controller = GroupChatChannelController(id: metadata.id, apiURL: apiURL, apiKey: apiKey)
            controller.activate()
            return controller
        case .ssh:
            guard let host = metadata.host, let user = metadata.user, let cmd = metadata.command else { return nil }
            let profile = SessionProfile(label: metadata.role, connection: .ssh, command: cmd, directory: "", host: host, user: user)
            let controller = SSHChannelController(id: metadata.id, profile: profile, instanceNumber: metadata.instanceNumber)
            controller.activate()
            return controller
        case .mcp:
            guard let endpointStr = metadata.endpoint, let endpoint = URL(string: endpointStr) else { return nil }
            let controller = MCPChannelController(id: metadata.id, endpoint: endpoint, label: metadata.role, instanceNumber: metadata.instanceNumber)
            controller.activate()
            return controller
        case .bridge:
            guard let cm = channelManagerRef else { return nil }
            let controller = BridgeChannelController(id: metadata.id, channelManager: cm, instanceNumber: metadata.instanceNumber)
            return controller
        }
    }

    private func applyAppearance(_ appearance: AppearanceConfig) {
        guard let window = windowController?.window else { return }
        if let color = NSColor(hexString: appearance.backgroundColor) {
            window.backgroundColor = color
        }
        window.alphaValue = CGFloat(appearance.transparency)
    }

    private func checkForCrashes(lastLaunch: Date?) {
        let since = lastLaunch ?? Date.distantPast
        let crashes = crashScanner.scanForCrashes(since: since)
        guard let crash = crashes.first else { return }

        // Load persisted state for context
        let config = configService.load()
        let persistedHistory = HistoryBuffer.loadPersistedSnapshot()

        let alert = NSAlert()
        alert.messageText = "Holoscape Crashed"

        var contextLines: [String] = ["A crash was detected from a previous session."]
        if let history = persistedHistory {
            let cmdCount = history.recentCommands.count
            let errorCount = history.recentErrors.count
            if cmdCount > 0 { contextLines.append("Last \(cmdCount) commands captured.") }
            if errorCount > 0 { contextLines.append("\(errorCount) errors logged before crash.") }
        }
        if !config.channels.isEmpty {
            contextLines.append("\(config.channels.count) channels were active.")
        }
        contextLines.append("\nSubmit a crash report?")
        alert.informativeText = contextLines.joined(separator: " ")

        alert.addButton(withTitle: "Submit Report")
        alert.addButton(withTitle: "Dismiss")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            let report = CrashReport(
                crashTrace: String(crash.content.prefix(10000)),
                lastChannelState: config.channels.isEmpty ? nil : config.channels,
                timestamp: crash.creationDate,
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                appVersion: appVersion(),
                hardwareModel: hardwareModel(),
                historySnapshot: persistedHistory
            )
            let service = self.bugReportService
            Task {
                do {
                    let response = try await service.submitCrashReport(report)
                    if !response.success {
                        service.savePendingCrashReport(report)
                    }
                } catch {
                    service.savePendingCrashReport(report)
                }
            }
        }
    }

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Holoscape")
        appMenu.addItem(withTitle: "About Holoscape", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Holoscape", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu (for standard text editing)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Help menu
        let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "Help")
        let reportBugItem = NSMenuItem(title: "Report Bug", action: #selector(showBugReportDialog), keyEquivalent: "b")
        reportBugItem.keyEquivalentModifierMask = [.command, .shift]
        reportBugItem.target = self
        helpMenu.addItem(reportBugItem)
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
    }
}

// MARK: - System Info Helpers

extension AppDelegate {
    func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}

// MARK: - NSColor hex extension

extension NSColor {
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6,
              let value = UInt64(hex, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
