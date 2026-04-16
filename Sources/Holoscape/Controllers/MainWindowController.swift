import AppKit

@MainActor
class MainWindowController: NSObject, NSWindowDelegate, NSSplitViewDelegate,
    TabBarViewDelegate, SidebarViewDelegate, SessionLauncherDelegate,
    InputBoxViewDelegate, ChannelControllerDelegate, NotificationChannelSwitchDelegate,
    SplitPaneManagerDelegate {

    let window: NSWindow
    let channelManager: ChannelManager
    private let configService: ConfigService
    private var profileManager: SessionProfileManager?

    private let splitView = NSSplitView()
    private let sidebarContainer = NSView()
    private let sessionLauncher = SessionLauncherView(frame: .zero)
    private let sidebarView = SidebarView(frame: .zero)
    private let tabBar = TabBarView(frame: .zero)
    private let splitPaneManager = SplitPaneManager(frame: .zero)
    private let inputBox: InputBoxView
    private let inputContainer: NSScrollView

    private(set) var activeChannelId: UUID?
    private var cachedShader: CompiledShader?
    private var sidebarExpanded: Bool = true
    nonisolated(unsafe) private var elapsedTimeTimer: Timer?
    private var notificationService: NotificationService?
    let historyBuffer = HistoryBuffer()
    weak var apiServer: HoloscapeAPIServer?
    private let bugReportService = BugReportService()
    private var bugReportDialog: BugReportDialog?
    private let launchTime = Date()
    private var inputHeightConstraint: NSLayoutConstraint?
    private let inputMinHeight: CGFloat = 40
    private let inputMaxHeight: CGFloat = 120

    /// Coalesces multiple refreshAllTabs() calls into a single
    /// layout pass at the end of the current run loop cycle.
    private var refreshScheduled: Bool = false

    /// Coalesces saveState() calls — waits 1s after last request before writing.
    private var saveStateWorkItem: DispatchWorkItem?

    private let sidebarWidth: CGFloat = 220
    private let launcherHeight: CGFloat = 36

    init(channelManager: ChannelManager, configService: ConfigService) {
        self.channelManager = channelManager
        self.configService = configService

        // Create window
        let windowRect = NSRect(x: 100, y: 100, width: 1000, height: 700)
        self.window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        // Create input box
        self.inputContainer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 40))
        self.inputBox = InputBoxView(frame: inputContainer.contentView.bounds)
        inputContainer.documentView = inputBox
        inputContainer.setAccessibilityElement(false)
        inputBox.isVerticallyResizable = true
        inputBox.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        inputBox.textContainer?.widthTracksTextView = true

        // Load sidebar state and compile shader if configured
        let config = configService.load()
        self.sidebarExpanded = config.sidebarExpanded ?? true

        super.init()
        recompileShader(path: config.appearance.customShaderPath)

        window.delegate = self
        window.title = "Holoscape"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0)
        window.isOpaque = false

        tabBar.tabDelegate = self
        sidebarView.sidebarDelegate = self
        sessionLauncher.launcherDelegate = self
        inputBox.inputDelegate = self
        splitPaneManager.splitDelegate = self

        setupLayout()
        setupKeyboardShortcuts()

        window.makeFirstResponder(inputBox)

        // Defer sidebar state application until after layout
        DispatchQueue.main.async { [self] in
            self.applySidebarState()
        }

        // Refresh elapsed time on tabs every 60 seconds
        elapsedTimeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAllTabs() }
        }
    }

    deinit {
        elapsedTimeTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    /// Set the notification service after initialization.
    func setNotificationService(_ service: NotificationService) {
        self.notificationService = service
    }

    /// Set the profile manager after services are initialized.
    func setProfileManager(_ manager: SessionProfileManager) {
        self.profileManager = manager
        refreshLauncher()
    }

    private func setupLayout() {
        guard let contentView = window.contentView else { return }

        // Configure split view
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(splitView)

        // Sidebar container: launcher at top, tab list below
        sidebarContainer.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.wantsLayer = true
        sidebarContainer.layer?.backgroundColor = NSColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1.0).cgColor

        sessionLauncher.translatesAutoresizingMaskIntoConstraints = false
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.addSubview(sessionLauncher)
        sidebarContainer.addSubview(sidebarView)

        NSLayoutConstraint.activate([
            sessionLauncher.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            sessionLauncher.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            sessionLauncher.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            sessionLauncher.heightAnchor.constraint(equalToConstant: launcherHeight),

            sidebarView.topAnchor.constraint(equalTo: sessionLauncher.bottomAnchor),
            sidebarView.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            sidebarView.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
        ])

        // Right pane: tab bar (hidden when sidebar expanded) + terminal + input
        let rightPane = NSView()
        rightPane.translatesAutoresizingMaskIntoConstraints = false
        rightPane.setAccessibilityElement(false)
        rightPane.setAccessibilityRole(.group)

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        splitPaneManager.translatesAutoresizingMaskIntoConstraints = false
        inputContainer.translatesAutoresizingMaskIntoConstraints = false

        rightPane.addSubview(tabBar)
        rightPane.addSubview(splitPaneManager)
        rightPane.addSubview(inputContainer)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: rightPane.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 32),

            splitPaneManager.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            splitPaneManager.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            splitPaneManager.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            splitPaneManager.bottomAnchor.constraint(equalTo: inputContainer.topAnchor),

            inputContainer.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            inputContainer.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            inputContainer.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor),
        ])

        // Input box auto-grow: start at min height, grow up to max
        let ihc = inputContainer.heightAnchor.constraint(equalToConstant: inputMinHeight)
        ihc.isActive = true
        inputHeightConstraint = ihc

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inputTextDidChange(_:)),
            name: NSText.didChangeNotification,
            object: inputBox
        )

        // Add panes to split view
        splitView.addArrangedSubview(sidebarContainer)
        splitView.addArrangedSubview(rightPane)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: contentView.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])

        // Set holding priorities
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)      // sidebar can shrink
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)     // terminal keeps space
    }

    private func setupKeyboardShortcuts() {
        let newItem = NSMenuItem(title: "New Session", action: #selector(handleNewSession), keyEquivalent: "n")
        newItem.target = self

        let newChannelItem = NSMenuItem(title: "New Channel", action: #selector(showChannelPicker), keyEquivalent: "")
        newChannelItem.target = self

        let closeItem = NSMenuItem(title: "Close Channel", action: #selector(closeActiveChannel), keyEquivalent: "w")
        closeItem.target = self

        let toggleSidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "s")
        toggleSidebarItem.keyEquivalentModifierMask = [.command, .shift]
        toggleSidebarItem.target = self

        if let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu {
            fileMenu.addItem(newItem)
            fileMenu.addItem(newChannelItem)
            fileMenu.addItem(closeItem)
            fileMenu.addItem(NSMenuItem.separator())
            fileMenu.addItem(toggleSidebarItem)
        }

        // View menu with timestamp toggle
        if let viewMenu = NSApp.mainMenu?.item(withTitle: "View")?.submenu {
            let timestampItem = NSMenuItem(title: "Show Timestamps", action: #selector(toggleTimestamps), keyEquivalent: "t")
            timestampItem.target = self
            viewMenu.addItem(timestampItem)
        }

        // Cmd+1-9 channel switching via local event monitor
        setupChannelSwitchShortcuts()
    }

    nonisolated(unsafe) private var keyMonitor: Any?

    private func setupChannelSwitchShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command) else { return event }

            let hasShift = event.modifierFlags.contains(.shift)

            // Cmd+D → split horizontal, Cmd+Shift+D → split vertical
            if event.keyCode == 2 {  // 'd'
                if hasShift {
                    self.splitPaneManager.splitVertical()
                } else {
                    self.splitPaneManager.splitHorizontal()
                }
                return nil
            }

            // Cmd+Shift+W → close split pane (only when multiple panes)
            if event.keyCode == 13 && hasShift {
                if self.splitPaneManager.paneCount > 1 {
                    self.splitPaneManager.closeActivePane()
                }
                return nil  // consume even with 1 pane to prevent system handling
            }

            // Key codes 18-26 map to digits 1-9
            let digitKeyCodes: [UInt16: Int] = [
                18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
            ]
            guard let position = digitKeyCodes[event.keyCode] else { return event }
            let channels = self.channelManager.allChannels()
            if position <= channels.count {
                self.switchToChannel(channels[position - 1].channelId)
                return nil
            }
            return event
        }
    }

    @objc func toggleTimestamps() {
        var config = configService.load()
        let current = config.showTimestamps ?? false
        config.showTimestamps = !current
        configService.save(config)
    }

    private func applySidebarState() {
        if sidebarExpanded {
            splitView.setPosition(sidebarWidth, ofDividerAt: 0)
            sidebarContainer.isHidden = false
            tabBar.isHidden = true
        } else {
            splitView.setPosition(0, ofDividerAt: 0)
            sidebarContainer.isHidden = true
            tabBar.isHidden = false
        }
    }

    // MARK: - Sidebar Toggle

    @objc func toggleSidebar() {
        sidebarExpanded.toggle()
        applySidebarState()
        // Populate the tab bar synchronously so its buttons are present the moment
        // the tab bar becomes visible. Without this, toggling the sidebar closed
        // unhides an empty tab bar until the next refreshAllTabs cycle fires.
        refreshAllTabsNow()

        // Persist
        var config = configService.load()
        config.sidebarExpanded = sidebarExpanded
        configService.save(config)
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        if let id = activeChannelId,
           let channel = channelManager.channel(for: id),
           ptyChannelTypes.contains(channel.channelType) {
            window.makeFirstResponder(channel.contentView)
        } else {
            window.makeFirstResponder(inputBox)
        }
    }

    // MARK: - NSSplitViewDelegate

    nonisolated func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        // Allow the sidebar (first subview at index 0) to collapse
        return splitView.subviews.first === subview
    }

    nonisolated func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 0  // allow full collapse; canCollapseSubview handles the rest
    }

    nonisolated func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 350  // maximum sidebar width
    }

    nonisolated func splitView(_ splitView: NSSplitView, shouldCollapseSubview subview: NSView, forDoubleClickOnDividerAt dividerIndex: Int) -> Bool {
        return splitView.subviews.first === subview
    }

    // MARK: - URL Scheme

    func openChannel(type: String, directory: String?, label: String?, command: String? = nil) {
        let dir = directory.map { URL(fileURLWithPath: $0) }

        switch type {
        case "shell":
            let dirName = dir?.lastPathComponent
            let effectiveLabel = label ?? dirName
            let channel = channelManager.createChannel(
                type: .shell,
                role: effectiveLabel ?? "Shell",
                workingDirectory: dir
            ) { id, _, _, instanceNum, workDir in
                ShellChannelController(id: id, instanceNumber: instanceNum, label: effectiveLabel, workingDirectory: workDir?.path)
            }
            channel.delegate = self
            channel.activate()
            if let cmd = command {
                // Small delay to let shell initialize before sending command
                let channelRef = channel
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    // Append a newline if missing so the command actually executes
                    // rather than being typed-but-not-submitted (affects URL scheme
                    // cmd= parameter and any other caller passing a raw command).
                    channelRef.sendInput(cmd.hasSuffix("\n") ? cmd : cmd + "\n")
                }
            }
            switchToChannel(channel.channelId)

        case "agent":
            let channel = channelManager.createChannel(
                type: .agentDirect,
                role: label,
                workingDirectory: dir ?? URL(fileURLWithPath: NSHomeDirectory())
            ) { id, _, _, instanceNum, workDir in
                AgentChannelController(
                    id: id,
                    authType: .oauth,
                    workingDirectory: workDir,
                    userLabel: label,
                    instanceNumber: instanceNum
                )
            }
            channel.delegate = self
            channel.activate()
            switchToChannel(channel.channelId)

        default:
            NSLog("Holoscape openChannel: unknown type '\(type)'")
        }
    }

    // MARK: - Channel Operations

    private let ptyChannelTypes: Set<ChannelType> = [.shell, .agentDirect, .agentAPI, .ssh]

    func switchToChannel(_ id: UUID) {
        guard let channel = channelManager.channel(for: id) else { return }
        let previousLabel = activeChannelId.flatMap { channelManager.channel(for: $0)?.displayLabel }
        activeChannelId = id
        channel.hasUnread = false
        apiServer?.clearNotification(for: id)
        splitPaneManager.showContent(channel.contentView, channelId: id, compiledShader: cachedShader)
        refreshAllTabs()
        historyBuffer.recordChannelSwitch(from: previousLabel, to: channel.displayLabel)

        // PTY channels handle their own input — hide InputBox and focus the terminal
        if ptyChannelTypes.contains(channel.channelType) {
            inputContainer.isHidden = true
            inputHeightConstraint?.constant = 0
            window.makeFirstResponder(channel.contentView)
        } else {
            inputContainer.isHidden = false
            inputHeightConstraint?.constant = inputMinHeight
            window.makeFirstResponder(inputBox)
        }
    }

    /// Schedule a tab refresh for the end of the current run loop cycle.
    /// Multiple calls within the same cycle are coalesced into one.
    func scheduleRefreshAllTabs() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshAllTabsNow()
        }
    }

    /// Debounce saveState() — waits 1s after the last call before writing to disk.
    private func scheduleSaveState() {
        // Skip state persistence during UI testing to prevent cross-test pollution
        if CommandLine.arguments.contains("--ui-testing") &&
           !CommandLine.arguments.contains("--restore-channels") {
            return
        }
        saveStateWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.channelManager.saveState()
        }
        saveStateWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    /// Immediately refresh all tabs (use sparingly — prefer scheduleRefreshAllTabs).
    func refreshAllTabs() {
        refreshAllTabsNow()
    }

    private func refreshAllTabsNow() {
        let channels = channelManager.allChannels()
        // Sort: pinned first (by pinnedAt), then unpinned
        let pinned = channels.filter { channelManager.pinnedChannelIds.contains($0.channelId) }
            .sorted { (channelManager.pinnedTimestamps[$0.channelId] ?? .distantPast) < (channelManager.pinnedTimestamps[$1.channelId] ?? .distantPast) }
        let unpinned = channels.filter { !channelManager.pinnedChannelIds.contains($0.channelId) }
        let sorted = pinned + unpinned

        let notifications = apiServer?.channelNotifications ?? [:]
        tabBar.updateTabs(channels: sorted, activeId: activeChannelId, pinnedIds: channelManager.pinnedChannelIds, notifications: notifications)
        sidebarView.updateTabs(channels: sorted, activeId: activeChannelId, pinnedIds: channelManager.pinnedChannelIds, notifications: notifications)
    }

    func refreshLauncher() {
        guard let profileManager else { return }
        let (preconfigured, discovered, recent) = profileManager.allSessions()
        sessionLauncher.updateItems(preconfigured: preconfigured, discovered: discovered, recent: recent)
    }

    @objc func handleNewSession() {
        if sidebarExpanded {
            sessionLauncher.focus()
        } else {
            showChannelPicker()
        }
    }

    @objc func showChannelPicker() {
        let alert = NSAlert()
        alert.messageText = "New Channel"
        alert.informativeText = "Select channel type:"
        alert.addButton(withTitle: "Shell")
        alert.addButton(withTitle: "Agent (OAuth)")
        alert.addButton(withTitle: "Agent (API Key)")
        alert.addButton(withTitle: "Group Chat")
        alert.addButton(withTitle: "Bridge")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:                      // 1000 — Shell
            createShellChannel()
        case .alertSecondButtonReturn:                     // 1001 — Agent (OAuth)
            createAgentChannel(authType: .oauth)
        case .alertThirdButtonReturn:                      // 1002 — Agent (API Key)
            createAgentChannel(authType: .apiKey(""))
        case NSApplication.ModalResponse(rawValue: 1003):  // Group Chat
            createGroupChatChannel()
        case NSApplication.ModalResponse(rawValue: 1004):  // Bridge
            createBridgeChannel()
        default:
            break
        }
    }

    private func createShellChannel() {
        let channel = channelManager.createChannel(
            type: .shell,
            role: "Shell",
            workingDirectory: nil
        ) { id, _, _, instanceNum, _ in
            return ShellChannelController(id: id, instanceNumber: instanceNum)
        }
        channel.delegate = self
        channel.activate()
        switchToChannel(channel.channelId)
    }

    private func createAgentChannel(authType: AgentAuthType) {
        let projectsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("projects")
        let defaultDir = FileManager.default.fileExists(atPath: projectsDir.path)
            ? projectsDir
            : URL(fileURLWithPath: NSHomeDirectory())
        let channel = channelManager.createChannel(
            type: { switch authType { case .oauth: return ChannelType.agentDirect; case .apiKey: return ChannelType.agentAPI } }(),
            role: nil,
            workingDirectory: defaultDir
        ) { id, type, _, instanceNum, workDir in
            AgentChannelController(
                id: id,
                authType: authType,
                workingDirectory: workDir,
                userLabel: nil,
                instanceNumber: instanceNum
            )
        }
        channel.delegate = self
        channel.activate()
        switchToChannel(channel.channelId)
    }

    private func createGroupChatChannel() {
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

        guard !apiURL.isEmpty, !apiKey.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Chat Not Configured"
            alert.informativeText = "~/.claude/agent-chat.env not found or missing AGENT_CHAT_URL/AGENT_CHAT_API_KEY"
            alert.runModal()
            return
        }

        let channel = channelManager.createChannel(
            type: .groupChat,
            role: "Chat",
            workingDirectory: nil
        ) { id, _, _, _, _ in
            GroupChatChannelController(id: id, apiURL: apiURL, apiKey: apiKey)
        }
        channel.delegate = self
        channel.activate()
        switchToChannel(channel.channelId)
    }

    private func createBridgeChannel() {
        let cm = channelManager
        let channel = channelManager.createChannel(
            type: .bridge,
            role: "Bridge",
            workingDirectory: nil
        ) { id, _, _, instanceNum, _ in
            BridgeChannelController(id: id, channelManager: cm, instanceNumber: instanceNum)
        }
        channel.delegate = self
        channel.activate()
        switchToChannel(channel.channelId)
    }

    private func launchSession(from profile: SessionProfile) {
        let resolved = profile.resolved(with: configService.load().sshDefaults)
        let channel = channelManager.createChannel(from: resolved)
        channel.delegate = self
        channel.activate()
        profileManager?.recordRecentSession(label: profile.label)
        refreshLauncher()
        switchToChannel(channel.channelId)
    }

    @objc func closeActiveChannel() {
        guard let id = activeChannelId,
              let channel = channelManager.channel(for: id) else { return }

        // Show confirmation for active channels
        if channel.state == .active {
            let alert = NSAlert()
            alert.messageText = "Close Channel"
            alert.informativeText = "The channel \"\(channel.displayLabel)\" is still active. Are you sure you want to close it?"
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning

            if alert.runModal() != .alertFirstButtonReturn {
                return
            }
        }

        closeChannel(id: id)
    }

    func closeChannel(id: UUID) {
        channelManager.closeChannel(id: id)

        splitPaneManager.removeChannel(channelId: id)
        if activeChannelId == id {
            activeChannelId = nil
            if let first = channelManager.allChannels().first {
                switchToChannel(first.channelId)
                // switchToChannel already called refreshAllTabs + scheduleSaveState
                return
            }
            // Last channel was closed — create a fresh shell so the window isn't empty
            let channel = channelManager.createChannel(
                type: .shell,
                role: "Shell",
                workingDirectory: nil
            ) { id, _, _, instanceNum, _ in
                ShellChannelController(id: id, instanceNumber: instanceNum, workingDirectory: nil)
            }
            channel.delegate = self
            channel.activate()
            switchToChannel(channel.channelId)
            return
        }
        refreshAllTabs()
        scheduleSaveState()
    }

    // MARK: - Context Menu

    func buildContextMenu(for channelId: UUID) -> NSMenu? {
        guard let channel = channelManager.channel(for: channelId) else { return nil }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let closeItem = NSMenuItem(title: "Close", action: #selector(contextMenuClose(_:)), keyEquivalent: "")
        closeItem.target = self
        closeItem.representedObject = channelId
        menu.addItem(closeItem)

        let renameItem = NSMenuItem(title: "Rename", action: #selector(contextMenuRename(_:)), keyEquivalent: "")
        renameItem.target = self
        renameItem.representedObject = channelId
        menu.addItem(renameItem)

        let duplicateItem = NSMenuItem(title: "Duplicate", action: #selector(contextMenuDuplicate(_:)), keyEquivalent: "")
        duplicateItem.target = self
        duplicateItem.representedObject = channelId
        menu.addItem(duplicateItem)

        menu.addItem(NSMenuItem.separator())

        let reconnectItem = NSMenuItem(title: "Reconnect", action: #selector(contextMenuReconnect(_:)), keyEquivalent: "")
        reconnectItem.target = self
        reconnectItem.representedObject = channelId
        reconnectItem.isEnabled = channel.state == .disconnected
        menu.addItem(reconnectItem)

        menu.addItem(NSMenuItem.separator())

        // Pin/Unpin
        let isPinned = channelManager.pinnedChannelIds.contains(channelId)
        let pinTitle = isPinned ? "Unpin" : "Pin"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(contextMenuTogglePin(_:)), keyEquivalent: "")
        pinItem.target = self
        pinItem.representedObject = channelId
        menu.addItem(pinItem)

        menu.addItem(NSMenuItem.separator())

        let copyInfoItem = NSMenuItem(title: "Copy Session Info", action: #selector(contextMenuCopyInfo(_:)), keyEquivalent: "")
        copyInfoItem.target = self
        copyInfoItem.representedObject = channelId
        menu.addItem(copyInfoItem)

        return menu
    }

    @objc private func contextMenuClose(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let channel = channelManager.channel(for: id) else { return }

        if channel.state == .active {
            let alert = NSAlert()
            alert.messageText = "Close Channel"
            alert.informativeText = "The channel \"\(channel.displayLabel)\" is still active. Are you sure you want to close it?"
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning

            if alert.runModal() != .alertFirstButtonReturn {
                return
            }
        }

        closeChannel(id: id)
    }

    @objc private func contextMenuRename(_ sender: NSMenuItem) {
        // TODO: Implement inline rename
    }

    @objc private func contextMenuDuplicate(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let channel = channelManager.channel(for: id) else { return }

        if let profileManager, let label = channelManager.labelForChannel(id: id) {
            let profile = profileManager.resolve(label: label)
            launchSession(from: profile)
        } else {
            // Fallback: duplicate by channel type without a profile
            switch channel.channelType {
            case .shell:
                createShellChannel()
            case .agentDirect:
                createAgentChannel(authType: .oauth)
            case .agentAPI:
                createAgentChannel(authType: .apiKey(""))
            case .bridge:
                createBridgeChannel()
            case .groupChat:
                createGroupChatChannel()
            default:
                createShellChannel()
            }
        }
    }

    @objc private func contextMenuReconnect(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let channel = channelManager.channel(for: id) else { return }
        channel.retry()
    }

    @objc private func contextMenuTogglePin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        channelManager.togglePin(id: id)
        refreshAllTabs()
        scheduleSaveState()
    }

    @objc private func contextMenuCopyInfo(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let channel = channelManager.channel(for: id) else { return }

        var info = "Label: \(channel.displayLabel)\nType: \(channel.channelType.rawValue)"
        if let sshChannel = channel as? SSHChannelController {
            info += "\nHost: \(sshChannel.profile.host ?? "N/A")"
            info += "\nUser: \(sshChannel.profile.user ?? "N/A")"
            info += "\nDirectory: \(sshChannel.profile.directory)"
            info += "\nCommand: \(sshChannel.profile.command)"
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(info, forType: .string)
    }

    // MARK: - TabBarViewDelegate

    func tabBarView(_ tabBar: TabBarView, didSelectChannelWithId id: UUID) {
        switchToChannel(id)
    }

    // MARK: - SidebarViewDelegate

    func sidebarView(_ sidebar: SidebarView, didSelectChannelWithId id: UUID) {
        switchToChannel(id)
    }

    func sidebarView(_ sidebar: SidebarView, contextMenuForChannelWithId id: UUID) -> NSMenu? {
        return buildContextMenu(for: id)
    }

    // MARK: - SessionLauncherDelegate

    func sessionLauncher(_ launcher: SessionLauncherView, didSelectProfile label: String) {
        guard let profileManager else { return }
        let profile = profileManager.resolve(label: label)
        launchSession(from: profile)
        window.makeFirstResponder(inputBox)
    }

    func sessionLauncher(_ launcher: SessionLauncherView, didTypeNewName name: String) {
        guard let profileManager else { return }
        let profile = profileManager.resolve(label: name)
        launchSession(from: profile)
        window.makeFirstResponder(inputBox)
    }

    func sessionLauncherDidRequestRefresh(_ launcher: SessionLauncherView) {
        Task {
            if let profileManager {
                let discoveryService = ProjectDiscoveryService(configService: configService)
                _ = await discoveryService.refresh()
                refreshLauncher()
            }
        }
    }

    // MARK: - InputBoxViewDelegate

    func inputBoxView(_ inputBox: InputBoxView, didSubmitText text: String) {
        guard let id = activeChannelId,
              let channel = channelManager.channel(for: id) else { return }
        channel.sendInput(text)
        historyBuffer.recordCommand(text, channelName: channel.displayLabel)
        resizeInputBox()
        window.makeFirstResponder(inputBox)
    }

    @objc private func inputTextDidChange(_ notification: Notification) {
        resizeInputBox()
    }

    private func resizeInputBox() {
        guard let layoutManager = inputBox.layoutManager,
              let textContainer = inputBox.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height
        let padding: CGFloat = 12  // top + bottom inset
        let newHeight = min(max(usedHeight + padding, inputMinHeight), inputMaxHeight)
        inputHeightConstraint?.constant = newHeight
    }

    func inputBoxViewDidRequestPreviousHistory(_ inputBox: InputBoxView) {
        guard let id = activeChannelId,
              let channel = channelManager.channel(for: id),
              let prev = channel.commandHistory.previous() else { return }
        inputBox.setHistoryText(prev)
    }

    func inputBoxViewDidRequestNextHistory(_ inputBox: InputBoxView) {
        guard let id = activeChannelId,
              let channel = channelManager.channel(for: id) else { return }
        if let next = channel.commandHistory.next() {
            inputBox.setHistoryText(next)
        } else {
            inputBox.string = ""
        }
    }

    // MARK: - ChannelControllerDelegate

    func channelDidReceiveOutput(_ channel: any ChannelController) {
        if channel.channelId != self.activeChannelId {
            channel.hasUnread = true
            // Tabs stay in place — no reordering on output
            scheduleRefreshAllTabs()

            // Send desktop notification (use displayLabel instead of extracting full buffer)
            notificationService?.notifyIfNeeded(channel: channel, firstLine: channel.displayLabel)
        }
    }

    func channelStateDidChange(_ channel: any ChannelController, to state: ChannelState) {
        scheduleRefreshAllTabs()
        scheduleSaveState()
    }

    // MARK: - SplitPaneManagerDelegate

    func splitPaneManager(_ manager: SplitPaneManager, activePaneDidChange channelId: UUID?) {
        if let channelId {
            activeChannelId = channelId
            scheduleRefreshAllTabs()
        }
    }

    func recordAppearanceChange(_ settings: AppearanceConfig) {
        let config = configService.load()
        let old = config.appearance
        if old.themeName != settings.themeName {
            historyBuffer.recordSettingsChange(setting: "theme", oldValue: old.themeName ?? "Dark", newValue: settings.themeName ?? "Dark")
        }
        if old.fontFamily != settings.fontFamily {
            historyBuffer.recordSettingsChange(setting: "fontFamily", oldValue: old.fontFamily, newValue: settings.fontFamily)
        }
        if old.fontSize != settings.fontSize {
            historyBuffer.recordSettingsChange(setting: "fontSize", oldValue: "\(old.fontSize)", newValue: "\(settings.fontSize)")
        }
        if old.transparency != settings.transparency {
            historyBuffer.recordSettingsChange(setting: "transparency", oldValue: "\(old.transparency)", newValue: "\(settings.transparency)")
        }
        if old.skinName != settings.skinName {
            historyBuffer.recordSettingsChange(setting: "skin", oldValue: old.skinName ?? "Default", newValue: settings.skinName ?? "Default")
        }
        if old.customShaderPath != settings.customShaderPath {
            historyBuffer.recordSettingsChange(setting: "shader", oldValue: old.customShaderPath ?? "None", newValue: settings.customShaderPath ?? "None")
            recompileShader(path: settings.customShaderPath)
        }
    }

    private func recompileShader(path: String?) {
        guard let shaderPath = path else {
            cachedShader = nil
            // Re-show current channel without compositor
            if let id = activeChannelId { switchToChannel(id) }
            return
        }
        let url: URL
        if shaderPath.hasPrefix("/") || shaderPath.hasPrefix("~") {
            url = URL(fileURLWithPath: (shaderPath as NSString).expandingTildeInPath)
        } else if let bundled = Bundle.module.url(
            forResource: (shaderPath as NSString).deletingPathExtension,
            withExtension: (shaderPath as NSString).pathExtension
        ) {
            url = bundled
        } else {
            url = URL(fileURLWithPath: shaderPath)
        }
        do {
            cachedShader = try ShaderCompiler().compile(glslPath: url)
        } catch {
            NSLog("ShaderCompiler: failed to compile \(shaderPath): \(error)")
            cachedShader = nil
        }
        // Re-show current channel with new (or no) compositor
        if let id = activeChannelId { switchToChannel(id) }
    }

    // MARK: - Bug Report

    func showBugReportDialog() {
        guard let activeId = activeChannelId,
              let activeChannel = channelManager.channel(for: activeId) else { return }

        let allChannels = channelManager.allChannels()
        let channelStates = allChannels.map {
            ChannelStateInfo(
                channelName: $0.displayLabel,
                channelType: $0.channelType,
                state: "\($0.state)"
            )
        }

        let config = configService.load()
        let appearanceSummary = "Theme: \(config.appearance.themeName ?? "Dark"), Font: \(config.appearance.fontFamily) \(config.appearance.fontSize)pt, Transparency: \(config.appearance.transparency)"

        let context = BugReportDialog.Context(
            activeChannelName: activeChannel.displayLabel,
            activeChannelType: activeChannel.channelType.rawValue,
            allChannelStates: channelStates,
            lastOutputLines: activeChannel.lastLines(50),
            appearanceConfig: appearanceSummary,
            splitLayout: config.splitLayout.map { "\($0)" },
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: Self.hardwareModel(),
            uptime: Date().timeIntervalSince(launchTime)
        )

        let dialog = BugReportDialog()
        dialog.delegate = self
        dialog.show(in: window, context: context)
        bugReportDialog = dialog
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(decoding: model.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

// MARK: - BugReportDialogDelegate

extension MainWindowController: BugReportDialogDelegate {
    func bugReportDialog(_ dialog: BugReportDialog, didSubmitDescription description: String, screenshot: Data?) {
        guard let activeId = activeChannelId,
              let activeChannel = channelManager.channel(for: activeId) else { return }

        let allChannels = channelManager.allChannels()
        let channelStates = allChannels.map {
            ChannelStateInfo(
                channelName: $0.displayLabel,
                channelType: $0.channelType,
                state: "\($0.state)"
            )
        }

        let config = configService.load()
        let appearanceSummary = "Theme: \(config.appearance.themeName ?? "Dark"), Font: \(config.appearance.fontFamily) \(config.appearance.fontSize)pt"

        let report = BugReport(
            channelName: activeChannel.displayLabel,
            channelType: activeChannel.channelType,
            lastOutputLines: activeChannel.lastLines(100),
            timestamp: Date(),
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            description: description,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            hardwareModel: Self.hardwareModel(),
            allChannelStates: channelStates,
            appearanceConfig: appearanceSummary,
            splitLayout: config.splitLayout.map { "\($0)" },
            uptime: Date().timeIntervalSince(launchTime),
            historyBuffer: historyBuffer.snapshot(),
            screenshotData: screenshot
        )

        let service = bugReportService
        Task {
            do {
                let response = try await service.submitBugReport(report)
                await MainActor.run {
                    if response.success {
                        self.showSubmitConfirmation(success: true, message: response.message)
                    } else {
                        service.savePendingBugReport(report)
                        self.showSubmitConfirmation(success: false, message: response.message)
                    }
                }
            } catch {
                service.savePendingBugReport(report)
                await MainActor.run {
                    self.showSubmitConfirmation(success: false, message: "Network error — report saved locally for retry.")
                }
            }
        }

        bugReportDialog = nil
    }

    private func showSubmitConfirmation(success: Bool, message: String?) {
        let alert = NSAlert()
        if success {
            alert.messageText = "Report Submitted"
            alert.informativeText = message ?? "Thank you! Your bug report has been submitted."
            alert.alertStyle = .informational
        } else {
            alert.messageText = "Submission Issue"
            alert.informativeText = message ?? "Report saved locally and will be retried on next launch."
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in }
    }
}
