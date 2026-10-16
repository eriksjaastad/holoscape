import Foundation

/// Owns the durable channel graph independently from live channel presentation.
///
/// `ChannelManager` remains responsible for constructing controllers and their tab
/// order. This object owns the transaction state that must survive failed saves,
/// partial restores, close cleanup, and broker-session recovery.
@MainActor
final class ChannelPersistenceTransactions {
    struct Snapshot {
        let channelOrder: [UUID]
        let channels: [UUID: any ChannelController]
        let channelLabels: [UUID: String]
        let pinnedTimestamps: [UUID: Date]
    }

    private let configService: ConfigService
    private let launchRecoveryState: LaunchRecoveryState

    private(set) var closingChannelIDs: Set<UUID> = []
    private var completedClosingChannelIDs: Set<UUID> = []
    private(set) var suppressedRecoveredBrokerSessionIDs: Set<BrokerSessionID> = []
    private(set) var restoredBrokerSessionIDs: [UUID: BrokerSessionID] = [:]
    private var unrestoredSavedChannels: [(index: Int, metadata: ChannelMetadata)] = []
    private var highWaterMarks: [String: Int] = [:]
    private(set) var closePersistenceFailure: String?

    init(configService: ConfigService, launchRecoveryState: LaunchRecoveryState) {
        self.configService = configService
        self.launchRecoveryState = launchRecoveryState
    }

    func beginClosing(_ id: UUID) -> Bool {
        closingChannelIDs.insert(id).inserted
    }

    func markClosingCompleted(_ id: UUID) {
        completedClosingChannelIDs.insert(id)
    }

    func retainCleanupFailure(_ failure: String) {
        closePersistenceFailure = failure
    }

    func recordRestoredBrokerSession(_ brokerSessionID: BrokerSessionID, for channelID: UUID, suppressRecovery: Bool) {
        restoredBrokerSessionIDs[channelID] = brokerSessionID
        if suppressRecovery {
            suppressedRecoveredBrokerSessionIDs.insert(brokerSessionID)
        }
    }

    func beginRestore(_ config: HoloscapeConfig) {
        for (label, highWaterMark) in config.channelInstanceHighWaterMarks ?? [:] {
            let key = label.lowercased()
            highWaterMarks[key] = max(highWaterMarks[key, default: 0], highWaterMark)
        }
        unrestoredSavedChannels = []
    }

    func recordUnrestored(_ metadata: ChannelMetadata, at index: Int) {
        unrestoredSavedChannels.append((index, metadata))
        recordRestoredInstanceNumber(metadata.instanceNumber, for: metadata.role)
    }

    func hasUnrestoredChannel(id: UUID) -> Bool {
        unrestoredSavedChannels.contains { $0.metadata.id == id }
    }

    func recordRestoredInstanceNumber(_ instanceNumber: Int?, for label: String) {
        let key = label.lowercased()
        highWaterMarks[key] = max(highWaterMarks[key, default: 0], instanceNumber ?? 1)
    }

    func nextInstanceNumber(for label: String, activeCount: Int) -> Int? {
        let key = label.lowercased()
        let highWaterMark = highWaterMarks[key, default: 0]
        if activeCount == 0 && highWaterMark == 0 {
            highWaterMarks[key] = 1
            return nil
        }
        let next = max(highWaterMark, activeCount) + 1
        highWaterMarks[key] = next
        return next
    }

    func load() -> HoloscapeConfig {
        configService.load()
    }

    /// Saves one complete channel-graph transaction and returns closures whose
    /// presentation objects can now be released because their deletion is durable.
    func save(_ snapshot: Snapshot) -> (didSave: Bool, finalizedClosureIDs: Set<UUID>) {
        guard launchRecoveryState.allowsChannelPersistence else {
            NSLog("ChannelManager refused to save channels during launch recovery (\(launchRecoveryState.phase))")
            return (false, [])
        }

        var config = configService.load()
        config.channels = snapshot.channelOrder.compactMap { id in
            guard !completedClosingChannelIDs.contains(id), let channel = snapshot.channels[id] else { return nil }
            return metadata(
                for: channel,
                role: snapshot.channelLabels[id] ?? channel.displayLabel,
                pinnedAt: snapshot.pinnedTimestamps[id],
                restoredBrokerSessionID: restoredBrokerSessionIDs[id],
                closeTombstone: closingChannelIDs.contains(id)
            )
        }
        for (index, metadata) in unrestoredSavedChannels {
            config.channels.insert(metadata, at: min(index, config.channels.count))
        }
        config.channelInstanceHighWaterMarks = highWaterMarks

        guard configService.save(config) else { return (false, []) }
        closePersistenceFailure = nil
        let finalizedClosureIDs = completedClosingChannelIDs
        completedClosingChannelIDs.removeAll()
        closingChannelIDs.subtract(finalizedClosureIDs)
        for id in finalizedClosureIDs {
            restoredBrokerSessionIDs.removeValue(forKey: id)
        }
        return (true, finalizedClosureIDs)
    }

    func persistenceFailure(fallback: String) -> String {
        configService.lastDiagnostic?.message ?? fallback
    }

    private func metadata(
        for channel: any ChannelController,
        role: String,
        pinnedAt: Date?,
        restoredBrokerSessionID: BrokerSessionID?,
        closeTombstone: Bool
    ) -> ChannelMetadata {
        var host: String?
        var user: String?
        var command: String?
        var endpoint: String?
        var apiURL: String?
        var apiKeyEnv: String?
        var useRawLabel: Bool?
        var workingDirectory: String?
        var staleBrokerSessionID: BrokerSessionID?
        var pendingExitedOutputRetirement: BrokerExitedOutputRetirement?

        if let shellChannel = channel as? ShellChannelController {
            workingDirectory = shellChannel.persistedWorkingDirectory
            staleBrokerSessionID = shellChannel.staleBrokerSessionID
            pendingExitedOutputRetirement = shellChannel.pendingExitedOutputRetirement
        } else if let agentChannel = channel as? AgentChannelController {
            workingDirectory = agentChannel.persistedWorkingDirectory
            command = agentChannel.persistedCommand
            useRawLabel = agentChannel.persistedUseRawLabel
            staleBrokerSessionID = agentChannel.staleBrokerSessionID
            pendingExitedOutputRetirement = agentChannel.pendingExitedOutputRetirement
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

        let brokerSessionID: BrokerSessionID?
        if staleBrokerSessionID != nil {
            brokerSessionID = nil
        } else if let shellChannel = channel as? ShellChannelController,
                  shellChannel.brokerSessionPersistenceIsAuthoritative {
            brokerSessionID = shellChannel.brokerSessionID
        } else if let agentChannel = channel as? AgentChannelController,
                  agentChannel.brokerSessionPersistenceIsAuthoritative {
            brokerSessionID = agentChannel.brokerSessionID
        } else {
            brokerSessionID = (channel as? ShellChannelController)?.brokerSessionID
                ?? (channel as? AgentChannelController)?.brokerSessionID
                ?? restoredBrokerSessionID
        }

        return ChannelMetadata(
            id: channel.channelId,
            type: channel.channelType,
            role: role,
            instanceNumber: channel.instanceNumber,
            useRawLabel: useRawLabel,
            workingDirectory: workingDirectory,
            customLabel: channel.customDisplayLabel,
            host: host,
            user: user,
            command: command,
            endpoint: endpoint,
            apiURL: apiURL,
            apiKeyEnv: apiKeyEnv,
            pinnedAt: pinnedAt,
            persistentState: channel.persistentState,
            brokerSessionID: brokerSessionID,
            staleBrokerSessionID: staleBrokerSessionID,
            pendingExitedOutputRetirement: pendingExitedOutputRetirement,
            closeTombstone: closeTombstone ? true : nil
        )
    }
}
