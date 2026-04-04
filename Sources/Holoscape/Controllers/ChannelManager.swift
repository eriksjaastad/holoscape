import Foundation

@MainActor
class ChannelManager {
    private var channels: [UUID: any ChannelController] = [:]
    private var channelOrder: [UUID] = []
    private var instanceCounters: [String: Int] = [:]
    private let configService: ConfigService

    init(configService: ConfigService) {
        self.configService = configService
    }

    /// Create a new channel and add it to the registry.
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
    }

    /// Get a channel by ID.
    func channel(for id: UUID) -> (any ChannelController)? {
        return channels[id]
    }

    /// Return all channels in tab order.
    func allChannels() -> [any ChannelController] {
        return channelOrder.compactMap { channels[$0] }
    }

    /// Move an unread channel's tab to the leftmost position.
    func moveUnreadToFront(id: UUID) {
        guard let index = channelOrder.firstIndex(of: id) else { return }
        channelOrder.remove(at: index)
        // Insert at the leftmost position (index 0)
        channelOrder.insert(id, at: 0)
    }

    /// Save current channel state to config.
    func saveState() {
        var config = configService.load()
        config.channels = channelOrder.compactMap { id -> ChannelMetadata? in
            guard let channel = channels[id] else { return nil }
            return ChannelMetadata(
                id: channel.channelId,
                type: channel.channelType,
                role: channel.displayLabel,
                context: nil,
                instanceNumber: nil,
                workingDirectory: nil
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
            }
        }
    }

    var count: Int { channels.count }

    // MARK: - Private

    private func nextInstanceNumber(for role: String) -> Int? {
        let key = role.lowercased()
        let current = instanceCounters[key, default: 0]
        instanceCounters[key] = current + 1
        // Only show instance number if there are multiple channels with this role
        let count = channels.values.filter { $0.displayLabel.lowercased().hasPrefix(key) }.count
        return count > 0 ? current + 1 : nil
    }

    private func defaultRole(for type: ChannelType) -> String {
        switch type {
        case .shell: return "Shell"
        case .agentDirect, .agentAPI: return "Agent"
        case .groupChat: return "Chat"
        }
    }
}
