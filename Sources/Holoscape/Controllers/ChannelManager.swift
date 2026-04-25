import Foundation

@MainActor
class ChannelManager {
    private var channels: [UUID: any ChannelController] = [:]
    private var channelOrder: [UUID] = []
    private var instanceCounters: [String: Int] = [:]
    private var highWaterMarks: [String: Int] = [:]
    private var channelLabels: [UUID: String] = [:]
    private(set) var pinnedChannelIds: Set<UUID> = []
    private(set) var pinnedTimestamps: [UUID: Date] = [:]
    private let configService: ConfigService

    init(configService: ConfigService) {
        self.configService = configService
    }

    /// Create a new channel and add it to the registry (V1 factory pattern).
    func createChannel(
        type: ChannelType,
        role: String?,
        workingDirectory: URL?,
        factory: (UUID, ChannelType, String, Int?, URL?) -> any ChannelController
    ) -> any ChannelController {
        let id = UUID()
        let effectiveRole = role ?? defaultRole(for: type)
        let instanceNumber = nextInstanceNumber(for: effectiveRole)
        let controller = factory(id, type, effectiveRole, instanceNumber, workingDirectory)
        channels[id] = controller
        channelOrder.append(id)
        channelLabels[id] = effectiveRole
        return controller
    }

    /// Create a new channel from a SessionProfile (V1.5).
    func createChannel(from profile: SessionProfile) -> any ChannelController {
        let id = UUID()
        let instanceNumber = nextInstanceNumber(for: profile.label)

        let controller: any ChannelController
        switch profile.connection {
        case .local:
            let dir = DefaultWorkingDirectory.expandedURL(from: profile.directory)
            if profile.command.contains("zsh") || profile.command.contains("bash") || profile.command == "/bin/zsh" || profile.command == "/bin/bash" {
                controller = ShellChannelController(id: id, instanceNumber: instanceNumber, workingDirectory: dir.path)
            } else {
                controller = AgentChannelController(
                    id: id,
                    authType: .oauth,
                    workingDirectory: dir,
                    userLabel: profile.label,
                    instanceNumber: instanceNumber,
                    useRawLabel: true,
                    command: profile.command
                )
            }
        case .ssh:
            controller = SSHChannelController(id: id, profile: profile, instanceNumber: instanceNumber)
        case .mcp:
            guard let endpointStr = profile.endpoint, let endpoint = URL(string: endpointStr) else {
                NSLog("ChannelManager: MCP profile '\(profile.label)' missing valid endpoint, skipping")
                controller = ShellChannelController(id: id, instanceNumber: instanceNumber)
                break
            }
            controller = MCPChannelController(id: id, endpoint: endpoint, label: profile.label, instanceNumber: instanceNumber)
        case .bridge:
            controller = BridgeChannelController(id: id, channelManager: self, instanceNumber: instanceNumber)
        case .agentChat:
            guard let apiURL = profile.apiURL, !apiURL.isEmpty else {
                NSLog("ChannelManager: Agent-chat profile '\(profile.label)' missing apiURL, skipping")
                controller = ShellChannelController(id: id, instanceNumber: instanceNumber)
                break
            }
            let apiKey = loadAPIKey(envVarName: profile.apiKeyEnv)
            controller = GroupChatChannelController(
                id: id, apiURL: apiURL, apiKey: apiKey,
                label: profile.label, instanceNumber: instanceNumber,
                apiKeyEnv: profile.apiKeyEnv
            )
        }

        channels[id] = controller
        channelOrder.append(id)
        channelLabels[id] = profile.label
        return controller
    }

    /// Close a channel. Returns true if confirmation is needed (active process).
    func needsCloseConfirmation(id: UUID) -> Bool {
        guard let channel = channels[id] else { return false }
        return channel.state == .active
    }

    /// Remove a channel from the registry.
    func closeChannel(id: UUID) {
        if let channel = channels[id] {
            channel.deactivate()
        }
        channels.removeValue(forKey: id)
        channelOrder.removeAll { $0 == id }
        channelLabels.removeValue(forKey: id)
        // Note: highWaterMarks are NOT decremented on close (no renumbering)
    }

    /// Get a channel by ID.
    func channel(for id: UUID) -> (any ChannelController)? {
        return channels[id]
    }

    /// Return all channels in tab order.
    func allChannels() -> [any ChannelController] {
        return channelOrder.compactMap { channels[$0] }
    }

    /// Return all active agent channels (for bridge broadcasting).
    func agentChannels() -> [any ChannelController] {
        let agentTypes: Set<ChannelType> = [.agentDirect, .agentAPI, .ssh, .mcp]
        return allChannels().filter { agentTypes.contains($0.channelType) && $0.state == .active }
    }

    /// Move an unread channel's tab to the leftmost/topmost position.
    func moveUnreadToFront(id: UUID) {
        guard let index = channelOrder.firstIndex(of: id) else { return }
        channelOrder.remove(at: index)
        channelOrder.insert(id, at: 0)
    }

    /// Save current channel state to config.
    func saveState() {
        var config = configService.load()
        config.channels = channelOrder.compactMap { id -> ChannelMetadata? in
            guard let channel = channels[id] else { return nil }

            // Extract type-specific fields for persistence
            var host: String?
            var user: String?
            var command: String?
            var endpoint: String?
            var apiURL: String?
            var apiKeyEnv: String?

            var workingDir: String?

            if let shellChannel = channel as? ShellChannelController {
                workingDir = shellChannel.workingDirectory
            } else if let sshChannel = channel as? SSHChannelController {
                host = sshChannel.profile.host
                user = sshChannel.profile.user
                command = sshChannel.profile.command
            } else if let mcpChannel = channel as? MCPChannelController {
                endpoint = mcpChannel.endpoint.absoluteString
            } else if let chatChannel = channel as? GroupChatChannelController {
                apiURL = chatChannel.apiURL
                apiKeyEnv = chatChannel.apiKeyEnv
            }

            return ChannelMetadata(
                id: channel.channelId,
                type: channel.channelType,
                role: channel.displayLabel,
                context: nil,
                instanceNumber: nil,
                workingDirectory: workingDir,
                host: host,
                user: user,
                command: command,
                endpoint: endpoint,
                apiURL: apiURL,
                apiKeyEnv: apiKeyEnv,
                pinnedAt: pinnedTimestamps[id]
            )
        }
        configService.save(config)
    }

    /// Restore channels from saved config.
    func restoreState(
        factory: (ChannelMetadata) -> (any ChannelController)?
    ) {
        let config = configService.load()
        for metadata in config.channels {
            if let controller = factory(metadata) {
                channels[controller.channelId] = controller
                channelOrder.append(controller.channelId)
                channelLabels[controller.channelId] = metadata.role
                if let pinnedAt = metadata.pinnedAt {
                    pinnedChannelIds.insert(controller.channelId)
                    pinnedTimestamps[controller.channelId] = pinnedAt
                }
            }
        }
    }

    /// Toggle pin state for a channel.
    func togglePin(id: UUID) {
        if pinnedChannelIds.contains(id) {
            pinnedChannelIds.remove(id)
            pinnedTimestamps.removeValue(forKey: id)
        } else {
            pinnedChannelIds.insert(id)
            pinnedTimestamps[id] = Date()
        }
    }

    var count: Int { channels.count }

    /// Get the stored label for a channel (used for profile resolution on duplicate).
    func labelForChannel(id: UUID) -> String? {
        return channelLabels[id]
    }

    // MARK: - Private

    private func nextInstanceNumber(for label: String) -> Int? {
        let key = label.lowercased()
        let activeCount = channelLabels.values.filter { $0.lowercased() == key }.count
        let hwm = highWaterMarks[key, default: 0]

        if activeCount == 0 {
            // First channel with this label — no number
            highWaterMarks[key] = 1
            return nil
        } else {
            // Additional channel — assign next number
            let next = max(hwm, activeCount) + 1
            highWaterMarks[key] = next
            return next
        }
    }

    private func defaultRole(for type: ChannelType) -> String {
        switch type {
        case .shell: return "Shell"
        case .agentDirect, .agentAPI: return "Agent"
        case .groupChat: return "Chat"
        case .ssh: return "SSH"
        case .mcp: return "MCP"
        case .bridge: return "Bridge"
        }
    }

    /// Load API key from environment variable or fallback to agent-chat.env file.
    private func loadAPIKey(envVarName: String?) -> String {
        // Try environment variable first
        if let envName = envVarName, !envName.isEmpty,
           let value = ProcessInfo.processInfo.environment[envName], !value.isEmpty {
            return value
        }

        // Fallback to ~/.claude/agent-chat.env
        let envPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/agent-chat.env")
        if let content = try? String(contentsOf: envPath, encoding: .utf8) {
            for line in content.components(separatedBy: "\n") {
                if line.hasPrefix("AGENT_CHAT_API_KEY=") {
                    return String(line.dropFirst("AGENT_CHAT_API_KEY=".count))
                }
            }
        }
        return ""
    }
}
