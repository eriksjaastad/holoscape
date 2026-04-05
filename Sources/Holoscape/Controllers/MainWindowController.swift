import AppKit

@MainActor
class MainWindowController: NSObject, NSWindowDelegate, NSSplitViewDelegate,
    TabBarViewDelegate, SidebarViewDelegate, SessionLauncherDelegate,
    InputBoxViewDelegate, ChannelControllerDelegate {

    let window: NSWindow
    let channelManager: ChannelManager
    private let configService: ConfigService
    private var profileManager: SessionProfileManager?

    private let splitView = NSSplitView()
    private let sidebarContainer = NSView()
    private let sessionLauncher = SessionLauncherView(frame: .zero)
    private let sidebarView = SidebarView(frame: .zero)
    private let tabBar = TabBarView(frame: .zero)
    private let terminalContainer = TerminalContainerView(frame: .zero)
    private let inputBox: InputBoxView
    private let inputContainer: NSScrollView

    private var activeChannelId: UUID?
    private var sidebarExpanded: Bool = true
    private var elapsedTimeTimer: Timer?
    private var pinnedChannelIds: Set<UUID> = []
    private var pinnedTimestamps: [UUID: Date] = [:]

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
        inputBox.isVerticallyResizable = false
        inputBox.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 40)
        inputBox.textContainer?.widthTracksTextView = true

        // Load sidebar state
        let config = configService.load()
        self.sidebarExpanded = config.sidebarExpanded ?? true

        super.init()

        window.delegate = self
        window.title = "Holoscape"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0)
        window.isOpaque = false

        tabBar.tabDelegate = self
        sidebarView.sidebarDelegate = self
        sessionLauncher.launcherDelegate = self
        inputBox.inputDelegate = self

        setupLayout()
        setupKeyboardShortcuts()

        window.makeFirstResponder(inputBox)

        // Defer sidebar state application until after layout
        DispatchQueue.main.async { [self] in
            self.applySidebarState()
        }

        // Refresh elapsed time on tabs every 60 seconds
        elapsedTimeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllTabs()
            }
        }
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
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        inputContainer.translatesAutoresizingMaskIntoConstraints = false

        rightPane.addSubview(tabBar)
        rightPane.addSubview(terminalContainer)
        rightPane.addSubview(inputContainer)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: rightPane.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 32),

            terminalContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: inputContainer.topAnchor),

            inputContainer.leadingAnchor.constraint(equalTo: rightPane.leadingAnchor),
            inputContainer.trailingAnchor.constraint(equalTo: rightPane.trailingAnchor),
            inputContainer.bottomAnchor.constraint(equalTo: rightPane.bottomAnchor),
            inputContainer.heightAnchor.constraint(equalToConstant: 40),
        ])

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

    private var keyMonitor: Any?

    private func setupChannelSwitchShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command) else { return event }
            // Key codes 18-26 map to digits 1-9
            let digitKeyCodes: [UInt16: Int] = [
                18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
            ]
            guard let position = digitKeyCodes[event.keyCode] else { return event }
            let channels = self.channelManager.allChannels()
            if position <= channels.count {
                self.switchToChannel(channels[position - 1].channelId)
                return nil  // consume event
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
            sidebarContainer.isHidden = false
            splitView.setPosition(sidebarWidth, ofDividerAt: 0)
            tabBar.isHidden = true
        } else {
            sidebarContainer.isHidden = true
            splitView.setPosition(0, ofDividerAt: 0)
            tabBar.isHidden = false
        }
    }

    // MARK: - Sidebar Toggle

    @objc func toggleSidebar() {
        sidebarExpanded.toggle()
        applySidebarState()

        // Persist
        var config = configService.load()
        config.sidebarExpanded = sidebarExpanded
        configService.save(config)
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        window.makeFirstResponder(inputBox)
    }

    // MARK: - NSSplitViewDelegate

    nonisolated func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 150  // minimum sidebar width
    }

    nonisolated func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return 350  // maximum sidebar width
    }

    // MARK: - Channel Operations

    func switchToChannel(_ id: UUID) {
        guard let channel = channelManager.channel(for: id) else { return }
        activeChannelId = id
        channel.hasUnread = false
        terminalContainer.showContent(channel.contentView)
        refreshAllTabs()
    }

    func refreshAllTabs() {
        let channels = channelManager.allChannels()
        // Sort: pinned first (by pinnedAt), then unpinned
        let pinned = channels.filter { pinnedChannelIds.contains($0.channelId) }
            .sorted { (pinnedTimestamps[$0.channelId] ?? .distantPast) < (pinnedTimestamps[$1.channelId] ?? .distantPast) }
        let unpinned = channels.filter { !pinnedChannelIds.contains($0.channelId) }
        let sorted = pinned + unpinned

        tabBar.updateTabs(channels: sorted, activeId: activeChannelId, pinnedIds: pinnedChannelIds)
        sidebarView.updateTabs(channels: sorted, activeId: activeChannelId, pinnedIds: pinnedChannelIds)
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
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            createShellChannel()
        case .alertSecondButtonReturn:
            createAgentChannel(authType: .oauth)
        case .alertThirdButtonReturn:
            createAgentChannel(authType: .apiKey(""))
        case NSApplication.ModalResponse(rawValue: 1002):
            createGroupChatChannel()
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
            ShellChannelController(id: id, instanceNumber: instanceNum)
        }
        channel.delegate = self
        channel.activate()
        switchToChannel(channel.channelId)
    }

    private func createAgentChannel(authType: AgentAuthType) {
        let channel = channelManager.createChannel(
            type: { switch authType { case .oauth: return ChannelType.agentDirect; case .apiKey: return ChannelType.agentAPI } }(),
            role: nil,
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
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
        guard let id = activeChannelId else { return }
        closeChannel(id: id)
    }

    func closeChannel(id: UUID) {
        if channelManager.needsCloseConfirmation(id: id) {
            let alert = NSAlert()
            alert.messageText = "Close Channel?"
            alert.informativeText = "This channel has a running process. Close anyway?"
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        channelManager.closeChannel(id: id)

        if activeChannelId == id {
            activeChannelId = nil
            terminalContainer.clearContent()
            if let first = channelManager.allChannels().first {
                switchToChannel(first.channelId)
            }
        }
        refreshAllTabs()
    }

    // MARK: - Context Menu

    func buildContextMenu(for channelId: UUID) -> NSMenu? {
        guard let channel = channelManager.channel(for: channelId) else { return nil }

        let menu = NSMenu()

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
        let isPinned = pinnedChannelIds.contains(channelId)
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
        guard let id = sender.representedObject as? UUID else { return }
        closeChannel(id: id)
    }

    @objc private func contextMenuRename(_ sender: NSMenuItem) {
        // TODO: Implement inline rename
    }

    @objc private func contextMenuDuplicate(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let label = channelManager.labelForChannel(id: id) else { return }
        if let profileManager {
            let profile = profileManager.resolve(label: label)
            launchSession(from: profile)
        }
    }

    @objc private func contextMenuReconnect(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let channel = channelManager.channel(for: id) else { return }
        channel.retry()
    }

    @objc private func contextMenuTogglePin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        if pinnedChannelIds.contains(id) {
            pinnedChannelIds.remove(id)
            pinnedTimestamps.removeValue(forKey: id)
        } else {
            pinnedChannelIds.insert(id)
            pinnedTimestamps[id] = Date()
        }
        refreshAllTabs()
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
            // Only reorder unpinned channels
            if !pinnedChannelIds.contains(channel.channelId) {
                self.channelManager.moveUnreadToFront(id: channel.channelId)
            }
            self.refreshAllTabs()
        }
    }

    func channelStateDidChange(_ channel: any ChannelController, to state: ChannelState) {
        refreshAllTabs()
    }
}
