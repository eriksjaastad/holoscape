import Foundation

@MainActor
class ChannelManager {
    private var channels: [UUID: any ChannelController] = [:]
    private var channelOrder: [UUID] = []
    private var instanceCounters: [String: Int] = [:]
    private var highWaterMarks: [String: Int] = [:]
    private var channelLabels: [UUID: String] = [:]
    private var restoredBrokerSessionIDs: [UUID: BrokerSessionID] = [:]
    /// Last failure hit while reading the broker registry during restore. Non-nil
    /// means Holoscape could not tell whether broker sessions survived, so tabs
    /// were restored from saved metadata alone. Cleared by the next successful read.
    private(set) var brokerRegistryReadFailure: String?
    private(set) var pinnedChannelIds: Set<UUID> = []
    private(set) var pinnedTimestamps: [UUID: Date] = [:]
    private let configService: ConfigService
    let brokerSessionCoordinator: any BrokerSessionCoordinating
    private let brokerBackedShellCoordinator: any BrokerSessionCoordinating

    var brokerBackedTerminalCoordinator: any BrokerSessionCoordinating {
        brokerBackedShellCoordinator
    }

    init(
        configService: ConfigService,
        brokerSessionCoordinator: any BrokerSessionCoordinating = BrokerSessionCoordinator(),
        brokerBackedShellCoordinator: (any BrokerSessionCoordinating)? = nil
    ) {
        self.configService = configService
        self.brokerSessionCoordinator = brokerSessionCoordinator
        self.brokerBackedShellCoordinator = brokerBackedShellCoordinator
            ?? BrokerSessionCoordinator(runtime: BrokerSessionHostClientRuntime.currentExecutableHostRuntime())
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
                controller = ShellChannelController.brokerBacked(
                    id: id,
                    instanceNumber: instanceNumber,
                    label: profile.label,
                    workingDirectory: dir.path,
                    coordinator: brokerBackedShellCoordinator
                )
            } else {
                controller = AgentChannelController.brokerBacked(
                    id: id,
                    authType: .oauth,
                    workingDirectory: dir,
                    userLabel: profile.label,
                    instanceNumber: instanceNumber,
                    useRawLabel: true,
                    command: profile.command,
                    coordinator: brokerBackedShellCoordinator
                )
            }
        case .ssh:
            controller = SSHChannelController(
                id: id,
                profile: profile,
                instanceNumber: instanceNumber,
                brokerSessionCoordinator: brokerSessionCoordinator
            )
        case .mcp:
            guard let endpointStr = profile.endpoint, let endpoint = URL(string: endpointStr) else {
                NSLog("ChannelManager: MCP profile '\(profile.label)' missing valid endpoint, skipping")
                controller = ShellChannelController.brokerBacked(
                    id: id,
                    instanceNumber: instanceNumber
                )
                break
            }
            controller = MCPChannelController(id: id, endpoint: endpoint, label: profile.label, instanceNumber: instanceNumber)
        case .bridge:
            controller = BridgeChannelController(id: id, channelManager: self, instanceNumber: instanceNumber)
        case .agentChat:
            guard let apiURL = profile.apiURL, !apiURL.isEmpty else {
                NSLog("ChannelManager: Agent-chat profile '\(profile.label)' missing apiURL, skipping")
                controller = ShellChannelController.brokerBacked(
                    id: id,
                    instanceNumber: instanceNumber
                )
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
        restoredBrokerSessionIDs.removeValue(forKey: id)
        // Note: highWaterMarks are NOT decremented on close (no renumbering)
    }

    /// Detach live channel views during app termination without mutating the
    /// saved tab registry. Broker-backed sessions must remain durable and
    /// reattachable after the UI process exits; this is intentionally different
    /// from `closeChannel`, which removes a tab from Holoscape's model.
    func detachAllChannelsForAppTermination() {
        for channel in allChannels() where channel.state != .disconnected {
            channel.deactivate()
        }
    }

    /// Get a channel by ID.
    func channel(for id: UUID) -> (any ChannelController)? {
        return channels[id]
    }

    /// Run the user-facing recovery action for a stale/disconnected tab and
    /// immediately persist the result. Stale broker-session recreation keeps the
    /// Holoscape tab UUID stable while replacing the stored broker session ID
    /// with the session created by the retry path.
    @discardableResult
    func recoverChannel(id: UUID) -> ChannelRecoveryAction? {
        guard let channel = channels[id], let action = channel.recoveryAction else { return nil }
        channel.retry()
        saveState()
        return action
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
            var staleBrokerSessionID: BrokerSessionID?

            if let shellChannel = channel as? ShellChannelController {
                workingDir = shellChannel.workingDirectory
                staleBrokerSessionID = shellChannel.staleBrokerSessionID
            } else if let agentChannel = channel as? AgentChannelController {
                workingDir = agentChannel.persistedWorkingDirectory
                command = agentChannel.persistedCommand
                staleBrokerSessionID = agentChannel.staleBrokerSessionID
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

            // A stale tab has no live broker handle to reattach; its dead session
            // identity is the only durable truth. Keeping the two mutually
            // exclusive stops the next launch from offering a dead session for
            // reattach while the tab reports recreate guidance.
            let brokerSessionID: BrokerSessionID?
            if staleBrokerSessionID != nil {
                brokerSessionID = nil
            } else {
                brokerSessionID = (channel as? ShellChannelController)?.brokerSessionID
                    ?? (channel as? AgentChannelController)?.brokerSessionID
                    ?? restoredBrokerSessionIDs[id]
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
                pinnedAt: pinnedTimestamps[id],
                persistentState: PersistentChannelState.fromRuntimeState(
                    channel.state,
                    source: staleBrokerSessionID == nil ? .processLifecycle : .brokerRegistry,
                    recoveryAction: channel.recoveryAction
                ),
                brokerSessionID: brokerSessionID,
                staleBrokerSessionID: staleBrokerSessionID
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
                if let brokerSessionID = metadata.brokerSessionID {
                    restoredBrokerSessionIDs[controller.channelId] = brokerSessionID
                }
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

    /// Reattachable broker sessions, or `nil` when the broker registry cannot be
    /// read during restore.
    ///
    /// A read failure must not be mistaken for "the registry is readable and this
    /// session is gone". Callers keep the saved tab and its persisted broker
    /// identity instead of replacing the session, and the failure is recorded in
    /// `brokerRegistryReadFailure` so the launch fails loudly instead of silently
    /// discarding what it could not read.
    private func reattachableBrokerSessions(context: String) -> [BrokerSessionRecord]? {
        do {
            let sessions = try brokerBackedShellCoordinator.reattachableSessions()
            brokerRegistryReadFailure = nil
            return sessions
        } catch {
            let failure = String(describing: error)
            brokerRegistryReadFailure = failure
            NSLog("ChannelManager could not read broker sessions during \(context): \(failure)")
            return nil
        }
    }

    func brokerBackedShellSessionToRestore(
        for channelID: UUID,
        brokerSessionID: BrokerSessionID? = nil
    ) -> BrokerSessionRecord? {
        guard let sessions = reattachableBrokerSessions(context: "shell tab restore") else { return nil }
        if let brokerSessionID,
           let exactMatch = sessions.first(where: { $0.channelType == .shell && $0.id == brokerSessionID }) {
            return exactMatch
        }
        return sessions.first { record in
            record.channelType == .shell && record.lastAttachedChannelID == channelID
        }
    }

    func brokerBackedAgentSessionToRestore(
        for channelID: UUID,
        channelType: ChannelType,
        brokerSessionID: BrokerSessionID? = nil
    ) -> BrokerSessionRecord? {
        guard let sessions = reattachableBrokerSessions(context: "agent tab restore") else { return nil }
        if let brokerSessionID,
           let exactMatch = sessions.first(where: { $0.channelType == channelType && $0.id == brokerSessionID }) {
            return exactMatch
        }
        return sessions.first { record in
            record.channelType == channelType && record.lastAttachedChannelID == channelID
        }
    }

    func firstUnmatchedBrokerBackedShellSessionToRestore() -> BrokerSessionRecord? {
        guard let sessions = reattachableBrokerSessions(context: "default shell recovery") else { return nil }
        return unmatchedBrokerBackedSessionsToRestore(from: sessions)
            .first { $0.channelType == .shell }
    }

    func unmatchedBrokerBackedSessionsToRestore() -> [BrokerSessionRecord] {
        guard let sessions = reattachableBrokerSessions(context: "crash recovery") else { return [] }
        return unmatchedBrokerBackedSessionsToRestore(from: sessions)
    }

    @discardableResult
    func restoreUnmatchedBrokerBackedSessions(
        factory: (ChannelMetadata) -> (any ChannelController)?
    ) -> Int {
        let records = unmatchedBrokerBackedSessionsToRestore()
        var restoredCount = 0
        for record in records {
            let metadata = ChannelMetadata(
                id: UUID(),
                type: record.channelType,
                role: restoredRole(for: record),
                workingDirectory: record.workingDirectory,
                command: restoredCommand(for: record),
                brokerSessionID: record.id
            )
            guard let controller = factory(metadata) else { continue }
            channels[controller.channelId] = controller
            channelOrder.append(controller.channelId)
            channelLabels[controller.channelId] = metadata.role
            restoredBrokerSessionIDs[controller.channelId] = record.id
            restoredCount += 1
        }
        if restoredCount > 0 {
            saveState()
        }
        return restoredCount
    }

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

    private func unmatchedBrokerBackedSessionsToRestore(
        from sessions: [BrokerSessionRecord]
    ) -> [BrokerSessionRecord] {
        let restoredChannelIDs = Set(channelOrder)
        // A tab owns both its live broker handle and the identity of a broker
        // session it went stale on. Both count as known so a dead session is
        // never resurrected as an extra "recovered" tab next to the tab that
        // already reports its recreate guidance.
        let persistedBrokerSessionIDs = Set(
            configService.load().channels
                .flatMap { [$0.brokerSessionID, $0.staleBrokerSessionID] }
                .compactMap { $0 }
        )
        let liveBrokerSessionIDs = Set(allChannels().flatMap { channel -> [BrokerSessionID] in
            switch channel {
            case let shell as ShellChannelController:
                return [shell.brokerSessionID, shell.staleBrokerSessionID].compactMap { $0 }
            case let agent as AgentChannelController:
                return [agent.brokerSessionID, agent.staleBrokerSessionID].compactMap { $0 }
            default:
                return []
            }
        })
        let knownBrokerSessionIDs = persistedBrokerSessionIDs.union(liveBrokerSessionIDs)

        return sessions.filter { record in
            switch record.channelType {
            case .shell, .agentDirect, .agentAPI:
                break
            case .groupChat, .ssh, .mcp, .bridge:
                return false
            }
            // A record the broker already marked stale is not a crash survivor: the
            // process behind it is gone, so surfacing it would only add a dead tab
            // that the user has to clear. A saved tab that owns this identity still
            // restores with its recreate guidance through the saved-tab lookup, which
            // is where that decision belongs.
            if record.lifecycle == .stale {
                return false
            }
            if knownBrokerSessionIDs.contains(record.id) {
                return false
            }
            if let lastAttachedChannelID = record.lastAttachedChannelID,
               restoredChannelIDs.contains(lastAttachedChannelID) {
                return false
            }
            return true
        }
    }

    private func restoredRole(for record: BrokerSessionRecord) -> String {
        if let label = record.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        return defaultRole(for: record.channelType)
    }

    private func restoredCommand(for record: BrokerSessionRecord) -> String? {
        guard record.channelType == .agentDirect || record.channelType == .agentAPI else { return nil }
        if record.command == "/usr/bin/env", record.arguments.count == 1 {
            return record.arguments[0]
        }
        if record.arguments.isEmpty {
            return record.command
        }
        return ([record.command] + record.arguments).map(shellEscaped).joined(separator: " ")
    }

    private func shellEscaped(_ token: String) -> String {
        if token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
           !token.contains("'") {
            return token
        }
        return "'\(token.replacingOccurrences(of: "'", with: "'\\''"))'"
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
