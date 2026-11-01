import Foundation

enum SessionProfileLaunchError: LocalizedError, Equatable {
    case invalidMCPEndpoint(label: String)
    case invalidAgentChatAPIURL(label: String)

    var errorDescription: String? {
        switch self {
        case .invalidMCPEndpoint(let label):
            return "The MCP session profile “\(label)” does not have a valid endpoint URL."
        case .invalidAgentChatAPIURL(let label):
            return "The Agent Chat session profile “\(label)” does not have a valid HTTP or HTTPS API URL."
        }
    }
}

enum ExternalServiceURLValidator {
    static func url(from rawValue: String?) -> URL? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasValidPercentEscapes(trimmed),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return components.url
    }

    private static func hasValidPercentEscapes(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x25 else {
                index += 1
                continue
            }
            guard index + 2 < bytes.count,
                  isASCIIHexDigit(bytes[index + 1]),
                  isASCIIHexDigit(bytes[index + 2]) else {
                return false
            }
            index += 3
        }
        return true
    }

    private static func isASCIIHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x46).contains(byte)
            || (0x61...0x66).contains(byte)
    }
}

@MainActor
class ChannelManager {
    private var channels: [UUID: any ChannelController] = [:]
    private var channelOrder: [UUID] = []
    private var channelLabels: [UUID: String] = [:]
    /// Last failure hit while reading the broker registry during restore. Non-nil
    /// means Holoscape could not tell whether broker sessions survived, so tabs
    /// were restored from saved metadata alone. Cleared by the next successful read.
    private(set) var brokerRegistryReadFailure: String?
    private(set) var pinnedChannelIds: Set<UUID> = []
    private(set) var pinnedTimestamps: [UUID: Date] = [:]
    var channelDidActuallyRemove: (@MainActor (any ChannelController) -> Void)?
    private let persistence: ChannelPersistenceTransactions
    let brokerSessionCoordinator: any BrokerSessionCoordinating
    private let brokerBackedShellCoordinator: any BrokerSessionCoordinating
    private let brokerRecoveryCoordinator: BrokerRecoveryCoordinator

    private var didPrepareBrokerRecovery = false
    private var preparedBrokerRecoverySessions: [BrokerSessionRecord]?

    var brokerBackedTerminalCoordinator: any BrokerSessionCoordinating {
        brokerBackedShellCoordinator
    }

    var closePersistenceFailure: String? {
        persistence.closePersistenceFailure
    }

    init(
        configService: ConfigService,
        brokerSessionCoordinator: any BrokerSessionCoordinating = BrokerSessionCoordinator(),
        brokerBackedShellCoordinator: (any BrokerSessionCoordinating)? = nil,
        launchRecoveryState: LaunchRecoveryState = LaunchRecoveryState(phase: .completed)
    ) {
        self.persistence = ChannelPersistenceTransactions(
            configService: configService,
            launchRecoveryState: launchRecoveryState
        )
        self.brokerSessionCoordinator = brokerSessionCoordinator
        let shellCoordinator = brokerBackedShellCoordinator
            ?? BrokerSessionCoordinator(runtime: BrokerSessionHostClientRuntime.currentExecutableHostRuntime())
        self.brokerBackedShellCoordinator = shellCoordinator
        self.brokerRecoveryCoordinator = BrokerRecoveryCoordinator(shellCoordinator)
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
    func createChannel(from profile: SessionProfile) throws -> any ChannelController {
        let mcpEndpoint: URL?
        let agentChatAPIURL: String?
        switch profile.connection {
        case .mcp:
            guard let endpoint = ExternalServiceURLValidator.url(from: profile.endpoint) else {
                throw SessionProfileLaunchError.invalidMCPEndpoint(label: profile.label)
            }
            mcpEndpoint = endpoint
            agentChatAPIURL = nil
        case .agentChat:
            guard let apiURL = ExternalServiceURLValidator.url(from: profile.apiURL) else {
                throw SessionProfileLaunchError.invalidAgentChatAPIURL(label: profile.label)
            }
            mcpEndpoint = nil
            agentChatAPIURL = apiURL.absoluteString
        case .local, .ssh, .bridge:
            mcpEndpoint = nil
            agentChatAPIURL = nil
        }

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
            guard let endpoint = mcpEndpoint else {
                throw SessionProfileLaunchError.invalidMCPEndpoint(label: profile.label)
            }
            controller = MCPChannelController(id: id, endpoint: endpoint, label: profile.label, instanceNumber: instanceNumber)
        case .bridge:
            controller = BridgeChannelController(id: id, channelManager: self, instanceNumber: instanceNumber)
        case .agentChat:
            guard let apiURL = agentChatAPIURL else {
                throw SessionProfileLaunchError.invalidAgentChatAPIURL(label: profile.label)
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
    func closeChannel(
        id: UUID,
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void = { _ in }
    ) {
        guard let channel = channels[id] else {
            completion(.completed)
            return
        }
        guard persistence.beginClosing(id) else {
            completion(.retryableFailure(TerminalSessionFailure(
                kind: .failed,
                description: "Channel close is already in progress"
            )))
            return
        }
        // Presentation removal and lifecycle ownership are separate. Keep this
        // controller in the saved order until teardown has serialized behind the
        // output lane and published any retirement-only broker authority.
        channel.deactivateForClose { [self] outcome in
            completion(handleClosingOutcome(outcome, id: id))
        }
        // Note: highWaterMarks are NOT decremented on close (no renumbering)
    }

    private func finishClosingChannel(id: UUID) -> TerminalCleanupOutcome {
        guard persistence.closingChannelIDs.contains(id), let channel = channels[id] else {
            return .completed
        }
        let ownsPendingRetirement = (channel as? ShellChannelController)?.pendingExitedOutputRetirement != nil
            || (channel as? AgentChannelController)?.pendingExitedOutputRetirement != nil
        if ownsPendingRetirement {
            // A failed completed-session retirement is hidden but durable. The
            // next launch restores its cleanup-only authority instead of losing
            // the broker ID when the tab-close callback releases its controller.
            guard persistClosingState(context: "retirement authority") else {
                return closePersistenceFailure(
                    fallback: "Channel state save failed while persisting retirement authority"
                )
            }
            return .retryableFailure(TerminalSessionFailure(
                kind: .failed,
                description: "Channel cleanup remains pending"
            ))
        }
        persistence.markClosingCompleted(id)
        guard persistClosingState(context: "completed removal") else {
            return closePersistenceFailure(
                fallback: "Channel state save failed while persisting completed removal"
            )
        }
        return .completed
    }

    private func handleClosingOutcome(_ outcome: TerminalCleanupOutcome, id: UUID) -> TerminalCleanupOutcome {
        switch outcome {
        case .completed:
            return finishClosingChannel(id: id)
        case .retryableFailure(let failure):
            let didSave = saveState()
            let message = didSave
                ? failure.description
                : persistence.persistenceFailure(
                    fallback: "Channel state save failed while persisting retryable cleanup failure"
                )
            persistence.retainCleanupFailure(message)
            NSLog("ChannelManager retained closed-channel cleanup authority: \(message)")
            if didSave {
                return outcome
            }
            return .retryableFailure(TerminalSessionFailure(kind: .failed, description: message))
        }
    }

    @discardableResult
    private func persistClosingState(context: String) -> Bool {
        guard saveState() else {
            let message = persistence.persistenceFailure(
                fallback: "Channel state save failed while persisting \(context)"
            )
            persistence.retainCleanupFailure(message)
            NSLog("ChannelManager could not persist closed-channel \(context): \(message)")
            return false
        }
        return true
    }

    private func closePersistenceFailure(fallback: String) -> TerminalCleanupOutcome {
        .retryableFailure(TerminalSessionFailure(
            kind: .failed,
            description: persistence.persistenceFailure(fallback: fallback)
        ))
    }

    /// Detach live channel views during app termination without mutating the
    /// saved tab registry. Broker-backed sessions must remain durable and
    /// reattachable after the UI process exits; this is intentionally different
    /// from `closeChannel`, which removes a tab from Holoscape's model.
    func detachAllChannelsForAppTermination(
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void = { _ in }
    ) {
        // A disconnected tab can still own an untracked broker generation when
        // startup created the process but registry persistence and rollback both
        // failed. Give every controller its teardown opportunity; deactivate is
        // idempotent for ordinary disconnected channels.
        // Closing channels are hidden presentation state, not released lifecycle
        // authority. Include them so quit cannot save and reply before an
        // in-flight close has published its final cleanup truth.
        let channels = channelOrder.compactMap { self.channels[$0] }
        guard !channels.isEmpty else {
            completion(.completed)
            return
        }
        var remaining = channels.count
        var firstFailure: TerminalSessionFailure?
        for channel in channels {
            channel.deactivateForAppTermination { outcome in
                if case .retryableFailure(let failure) = outcome, firstFailure == nil {
                    firstFailure = failure
                }
                remaining -= 1
                if remaining == 0 {
                    if let firstFailure {
                        completion(.retryableFailure(firstFailure))
                    } else {
                        completion(.completed)
                    }
                }
            }
        }
    }

    /// Get a channel by ID.
    func channel(for id: UUID) -> (any ChannelController)? {
        guard !persistence.closingChannelIDs.contains(id) else { return nil }
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
        return channelOrder.compactMap { id in
            persistence.closingChannelIDs.contains(id) ? nil : channels[id]
        }
    }

    /// Apply a user-owned display label without changing launch or process identity.
    @discardableResult
    func renameChannel(id: UUID, to label: String) -> Bool {
        guard let normalized = ChannelCustomDisplayLabel.normalized(label),
              let channel = channels[id] else { return false }
        channel.setCustomDisplayLabel(normalized)
        saveState()
        return true
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
    @discardableResult
    func saveState(splitLayout: SplitLayoutConfig? = nil) -> Bool {
        let result = persistence.save(.init(
            channelOrder: channelOrder,
            channels: channels,
            channelLabels: channelLabels,
            pinnedTimestamps: pinnedTimestamps,
            splitLayout: splitLayout
        ))
        if result.didSave {
            for id in result.finalizedClosureIDs {
                let removedChannel = channels.removeValue(forKey: id)
                channelOrder.removeAll { $0 == id }
                channelLabels.removeValue(forKey: id)
                if let removedChannel {
                    channelDidActuallyRemove?(removedChannel)
                }
            }
        }
        return result.didSave
    }

    /// Restore channels from saved config.
    func restoreState(
        factory: (ChannelMetadata) -> (any ChannelController)?
    ) {
        let config = persistence.load()
        var claimedBrokerSessionIDs: Set<BrokerSessionID> = []
        var restoredCloseCleanupControllers: [any ChannelController] = []
        persistence.beginRestore(config)
        for (index, metadata) in config.channels.enumerated() {
            // The factory may activate a controller and mutate broker ownership.
            // Retain duplicate persisted identities without invoking it so a
            // discarded duplicate cannot launch a hidden process or disappear
            // from the next successful save.
            if channels[metadata.id] != nil
                || persistence.hasUnrestoredChannel(id: metadata.id) {
                persistence.recordUnrestored(metadata, at: index)
                continue
            }
            if let brokerSessionID = metadata.brokerSessionID,
               claimedBrokerSessionIDs.contains(brokerSessionID) {
                // Do not construct a second controller for one durable process,
                // but retain the skipped tab metadata so a later save cannot
                // erase it before the persisted identity conflict is resolved.
                persistence.recordUnrestored(metadata, at: index)
                continue
            }
            guard let controller = factory(metadata) else {
                // The entry stays saved, so its ordinal stays reserved: a new
                // same-role tab must not reuse its number. It is not a live tab,
                // so it claims no channel or broker identity.
                persistence.recordUnrestored(metadata, at: index)
                continue
            }
            if channels[controller.channelId] == nil {
                controller.setCustomDisplayLabel(metadata.customLabel)
                channels[controller.channelId] = controller
                channelOrder.append(controller.channelId)
                channelLabels[controller.channelId] = metadata.role
                persistence.recordRestoredSavedChannel(controller.channelId, at: index)
                persistence.recordRestoredInstanceNumber(metadata.instanceNumber, for: metadata.role)
                if let brokerSessionID = metadata.brokerSessionID {
                    claimedBrokerSessionIDs.insert(brokerSessionID)
                    persistence.recordRestoredBrokerSession(
                        brokerSessionID,
                        for: controller.channelId,
                        suppressRecovery: metadata.closeTombstone == true
                    )
                }
                if let pinnedAt = metadata.pinnedAt {
                    pinnedChannelIds.insert(controller.channelId)
                    pinnedTimestamps[controller.channelId] = pinnedAt
                }
                if metadata.closeTombstone == true {
                    // Register the entire saved graph before cleanup can complete.
                    // A synchronous missing-session result may save immediately;
                    // deferring the callback prevents that save from dropping tabs
                    // that appear later in the persisted order.
                    _ = persistence.beginClosing(controller.channelId)
                    restoredCloseCleanupControllers.append(controller)
                }
            }
        }
        for controller in restoredCloseCleanupControllers {
            controller.resumeRestoredCloseCleanup { [weak self] outcome in
                _ = self?.handleClosingOutcome(outcome, id: controller.channelId)
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

    var count: Int { channels.count - persistence.closingChannelIDs.count }

    /// Reattachable broker sessions, or `nil` when the broker registry cannot be
    /// read during restore.
    ///
    /// A read failure must not be mistaken for "the registry is readable and this
    /// session is gone". Callers keep the saved tab and its persisted broker
    /// identity instead of replacing the session, and the failure is recorded in
    /// `brokerRegistryReadFailure` so the launch fails loudly instead of silently
    /// discarding what it could not read.
    /// Prepare broker recovery before any restore code performs synchronous
    /// record classification. All socket/status/retirement RPCs happen off-main.
    @discardableResult
    func prepareBrokerRecovery() async -> Bool {
        didPrepareBrokerRecovery = true
        do {
            let sessions = try await withCheckedThrowingContinuation { continuation in
                brokerRecoveryCoordinator.load { result in
                    continuation.resume(with: result)
                }
            }
            preparedBrokerRecoverySessions = sessions
            brokerRegistryReadFailure = nil
            return true
        } catch {
            preparedBrokerRecoverySessions = nil
            brokerRegistryReadFailure = String(describing: error)
            NSLog("ChannelManager could not read broker sessions during launch recovery: \(error)")
            return false
        }
    }

    private func reattachableBrokerSessions(context: String) -> [BrokerSessionRecord]? {
        if didPrepareBrokerRecovery {
            return preparedBrokerRecoverySessions
        }
        guard !brokerBackedShellCoordinator.requiresOffMainBrokerWork else {
            let failure = "Broker recovery inventory was not prepared before \(context)"
            brokerRegistryReadFailure = failure
            NSLog("ChannelManager cannot classify broker sessions during \(context): \(failure)")
            return nil
        }
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
        let liveSessions = sessions.filter {
            $0.lifecycle == .creating || $0.lifecycle == .running || $0.lifecycle == .detached
                || $0.lifecycle == .exiting || $0.lifecycle == .exited
        }
        if let brokerSessionID,
           let exactMatch = liveSessions.first(where: { $0.channelType == .shell && $0.id == brokerSessionID }) {
            return exactMatch
        }
        return liveSessions.first { record in
            record.channelType == .shell && record.lastAttachedChannelID == channelID
        }
    }

    func brokerBackedAgentSessionToRestore(
        for channelID: UUID,
        channelType: ChannelType,
        brokerSessionID: BrokerSessionID? = nil
    ) -> BrokerSessionRecord? {
        guard let sessions = reattachableBrokerSessions(context: "agent tab restore") else { return nil }
        let liveSessions = sessions.filter {
            $0.lifecycle == .creating || $0.lifecycle == .running || $0.lifecycle == .detached
                || $0.lifecycle == .exiting || $0.lifecycle == .exited
        }
        if let brokerSessionID,
           let exactMatch = liveSessions.first(where: { $0.channelType == channelType && $0.id == brokerSessionID }) {
            return exactMatch
        }
        return liveSessions.first { record in
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
        let firstRecoveredPersistenceIndex = channelOrder.count + persistence.unrestoredChannelCount
        var restoredCount = 0
        var deferredCount = 0
        for (index, record) in records.enumerated() {
            let role = restoredRole(for: record)
            let instanceNumber = nextInstanceNumber(for: role)
            let metadata = ChannelMetadata(
                id: UUID(),
                type: record.channelType,
                role: role,
                instanceNumber: instanceNumber,
                useRawLabel: record.channelType == .agentDirect || record.channelType == .agentAPI ? true : nil,
                workingDirectory: record.workingDirectory,
                command: restoredCommand(for: record),
                brokerSessionID: record.id
            )
            guard let controller = factory(metadata) else {
                persistence.recordUnrestored(metadata, at: firstRecoveredPersistenceIndex + index)
                deferredCount += 1
                continue
            }
            channels[controller.channelId] = controller
            channelOrder.append(controller.channelId)
            channelLabels[controller.channelId] = metadata.role
            persistence.recordRestoredInstanceNumber(metadata.instanceNumber, for: metadata.role)
            persistence.recordRestoredBrokerSession(record.id, for: controller.channelId, suppressRecovery: false)
            restoredCount += 1
        }
        if restoredCount > 0 || deferredCount > 0 {
            saveState()
        }
        return restoredCount
    }

    /// Get the stored label for a channel (used for profile resolution on duplicate).
    func labelForChannel(id: UUID) -> String? {
        return channelLabels[id]
    }

    func channel(matchingLaunchLabel label: String) -> (any ChannelController)? {
        channelOrder.compactMap { id -> (any ChannelController)? in
            guard channelLabels[id]?.caseInsensitiveCompare(label) == .orderedSame else { return nil }
            return channels[id]
        }.first
    }

    // MARK: - Private

    private func nextInstanceNumber(for label: String) -> Int? {
        let key = label.lowercased()
        let activeCount = channelLabels.values.filter { $0.lowercased() == key }.count
        return persistence.nextInstanceNumber(for: label, activeCount: activeCount)
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
        let restoredBrokerSessionIdentities = Set(persistence.restoredBrokerSessionIDs.values)
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
        let knownBrokerSessionIDs = restoredBrokerSessionIdentities
            .union(liveBrokerSessionIDs)
            .union(persistence.suppressedRecoveredBrokerSessionIDs)
            .union(persistence.unrestoredBrokerSessionIDs)

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

final class BrokerRecoveryCoordinator: @unchecked Sendable {
    private let coordinator: any BrokerSessionCoordinating
    private let queue = DispatchQueue(label: "holoscape.broker.launch-recovery", qos: .userInitiated)

    init(_ coordinator: any BrokerSessionCoordinating) {
        self.coordinator = coordinator
    }

    func load(
        completion: @escaping @Sendable (Result<[BrokerSessionRecord], Error>) -> Void
    ) {
        queue.async { [self] in
            completion(Result { try coordinator.reattachableSessions() })
        }
    }
}
