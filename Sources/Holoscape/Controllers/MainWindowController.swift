import AppKit

@MainActor
class MainWindowController: NSObject, NSWindowDelegate, TabBarViewDelegate, InputBoxViewDelegate, ChannelControllerDelegate {
    let window: NSWindow
    let channelManager: ChannelManager
    private let tabBar = TabBarView(frame: .zero)
    private let terminalContainer = TerminalContainerView(frame: .zero)
    private let inputBox: InputBoxView
    private var activeChannelId: UUID?

    init(channelManager: ChannelManager) {
        self.channelManager = channelManager

        // Create window
        let windowRect = NSRect(x: 100, y: 100, width: 1000, height: 700)
        self.window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        // Create input box
        let inputContainer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 40))
        self.inputBox = InputBoxView(frame: inputContainer.contentView.bounds)
        inputContainer.documentView = inputBox
        inputBox.isVerticallyResizable = false
        inputBox.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 40)
        inputBox.textContainer?.widthTracksTextView = true

        super.init()

        window.delegate = self
        window.title = "Holoscape"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0)
        window.isOpaque = false

        tabBar.tabDelegate = self
        inputBox.inputDelegate = self

        setupLayout(inputContainer: inputContainer)
        setupKeyboardShortcuts()

        // Set input box as first responder so keyboard works immediately
        window.makeFirstResponder(inputBox)
    }

    private func setupLayout(inputContainer: NSScrollView) {
        guard let contentView = window.contentView else { return }

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        inputContainer.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(tabBar)
        contentView.addSubview(terminalContainer)
        contentView.addSubview(inputContainer)

        NSLayoutConstraint.activate([
            // Tab bar at top
            tabBar.topAnchor.constraint(equalTo: contentView.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: 32),

            // Terminal container in center
            terminalContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: inputContainer.topAnchor),

            // Input box at bottom
            inputContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            inputContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            inputContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            inputContainer.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    private func setupKeyboardShortcuts() {
        // Cmd+N — new channel
        let newItem = NSMenuItem(title: "New Channel", action: #selector(showChannelPicker), keyEquivalent: "n")
        newItem.target = self

        // Cmd+W — close active channel
        let closeItem = NSMenuItem(title: "Close Channel", action: #selector(closeActiveChannel), keyEquivalent: "w")
        closeItem.target = self

        if let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu {
            fileMenu.addItem(newItem)
            fileMenu.addItem(closeItem)
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        window.makeFirstResponder(inputBox)
    }

    // MARK: - Channel Operations

    func switchToChannel(_ id: UUID) {
        guard let channel = channelManager.channel(for: id) else { return }
        activeChannelId = id
        channel.hasUnread = false
        terminalContainer.showContent(channel.contentView)
        refreshTabBar()
    }

    func refreshTabBar() {
        tabBar.updateTabs(channels: channelManager.allChannels(), activeId: activeChannelId)
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
            createAgentChannel(authType: .apiKey(""))  // TODO: prompt for key
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
        // Load chat config from agent-chat.env
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

    @objc func closeActiveChannel() {
        guard let id = activeChannelId else { return }
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
        activeChannelId = nil
        terminalContainer.clearContent()

        // Switch to first available channel
        if let first = channelManager.allChannels().first {
            switchToChannel(first.channelId)
        }
        refreshTabBar()
    }

    // MARK: - TabBarViewDelegate

    func tabBarView(_ tabBar: TabBarView, didSelectChannelWithId id: UUID) {
        switchToChannel(id)
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
            self.channelManager.moveUnreadToFront(id: channel.channelId)
            self.refreshTabBar()
        }
    }

    func channelStateDidChange(_ channel: any ChannelController, to state: ChannelState) {
        refreshTabBar()
    }
}
