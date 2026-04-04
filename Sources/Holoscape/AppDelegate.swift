import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private let configService = ConfigService()
    private let crashScanner = CrashReportScanner()
    private let bugReportService = BugReportService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Build menu bar
        setupMenuBar()

        // Load config and apply appearance
        let config = configService.load()

        // Create channel manager and window
        let channelManager = ChannelManager(configService: configService)
        windowController = MainWindowController(channelManager: channelManager)

        // Apply appearance
        applyAppearance(config.appearance)

        // Restore channels from saved state
        channelManager.restoreState { [weak self] metadata in
            self?.createChannelFromMetadata(metadata)
        }

        // If no channels restored, create a default shell
        if channelManager.count == 0 {
            let channel = channelManager.createChannel(
                type: .shell,
                role: "Shell",
                workingDirectory: nil
            ) { id, _, _, instanceNum, _ in
                ShellChannelController(id: id, instanceNumber: instanceNum)
            }
            channel.activate()
            windowController?.switchToChannel(channel.channelId)
        } else if let first = channelManager.allChannels().first {
            windowController?.switchToChannel(first.channelId)
        }

        windowController?.refreshTabBar()

        // Show window
        windowController?.window.makeKeyAndOrderFront(nil)

        // Check for crashes on previous launch
        checkForCrashes(lastLaunch: config.lastLaunchTimestamp)

        // Update launch timestamp
        var updatedConfig = config
        updatedConfig.lastLaunchTimestamp = Date()
        configService.save(updatedConfig)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Save channel state
        Task { @MainActor in
            windowController?.channelManager.saveState()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Private

    private func createChannelFromMetadata(_ metadata: ChannelMetadata) -> (any ChannelController)? {
        switch metadata.type {
        case .shell:
            let controller = ShellChannelController(id: metadata.id, instanceNumber: metadata.instanceNumber)
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

        let alert = NSAlert()
        alert.messageText = "Holoscape Crashed"
        alert.informativeText = "A crash was detected from a previous session. File a report?"
        alert.addButton(withTitle: "Submit Report")
        alert.addButton(withTitle: "Dismiss")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            let report = CrashReport(
                crashTrace: String(crash.content.prefix(10000)),
                lastChannelState: nil,
                timestamp: crash.creationDate,
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
            )
            let service = self.bugReportService
            Task {
                _ = try? await service.submitCrashReport(report)
            }
        }
    }

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Holoscape", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
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

        NSApp.mainMenu = mainMenu
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
