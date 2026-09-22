import Foundation

/// Immutable channel state handed to skin/shader/render code.
///
/// Controllers remain main-actor objects, and SwiftTerm internals remain view
/// details. Render paths consume this value snapshot so skins see durable tab
/// truth without reaching back into live controllers or external integrations.
struct ChannelRenderSnapshot: Equatable, Sendable {
    let channelID: UUID
    let channelIDOrdinal: Int32
    let channelType: ChannelType
    let displayLabel: String
    let isActive: Bool
    let hasUnread: Bool
    let persistentState: PersistentChannelState
    let recoveryAction: ChannelRecoveryAction?
    let agentIdentity: ChannelTabIdentityIndicator?
    let lastInteractionAt: Date
    let capturedAt: Date

    init(
        channelID: UUID,
        channelType: ChannelType,
        displayLabel: String,
        isActive: Bool,
        hasUnread: Bool,
        persistentState: PersistentChannelState,
        recoveryAction: ChannelRecoveryAction? = nil,
        agentIdentity: ChannelTabIdentityIndicator? = nil,
        lastInteractionAt: Date = .distantPast,
        capturedAt: Date = Date()
    ) {
        self.channelID = channelID
        self.channelIDOrdinal = Self.stableOrdinal(for: channelID)
        self.channelType = channelType
        self.displayLabel = displayLabel
        self.isActive = isActive
        self.hasUnread = hasUnread
        self.persistentState = persistentState
        self.recoveryAction = recoveryAction
        self.agentIdentity = agentIdentity
        self.lastInteractionAt = lastInteractionAt
        self.capturedAt = capturedAt
    }

    @MainActor
    init(channel: any ChannelController, isActive: Bool, capturedAt: Date = Date()) {
        self.init(
            channelID: channel.channelId,
            channelType: channel.channelType,
            displayLabel: channel.displayLabel,
            isActive: isActive,
            hasUnread: channel.hasUnread,
            persistentState: channel.persistentState,
            recoveryAction: channel.recoveryAction,
            agentIdentity: channel.tabIdentityIndicator,
            lastInteractionAt: channel.lastInteractionAt,
            capturedAt: capturedAt
        )
    }

    /// Merge several candidate signals into the render state that should win.
    /// Higher persistent-state display priority wins so routine output/running
    /// updates cannot hide needs-approval, error, or stale recovery states.
    func replacingStateWithHighestPriority(_ candidates: [PersistentChannelState]) -> ChannelRenderSnapshot {
        guard let winner = candidates.max(by: { lhs, rhs in
            lhs.kind.displayPriority < rhs.kind.displayPriority
        }) else {
            return self
        }
        return ChannelRenderSnapshot(
            channelID: channelID,
            channelType: channelType,
            displayLabel: displayLabel,
            isActive: isActive,
            hasUnread: hasUnread,
            persistentState: winner,
            recoveryAction: winner.recoveryAction ?? recoveryAction,
            agentIdentity: agentIdentity,
            lastInteractionAt: lastInteractionAt,
            capturedAt: capturedAt
        )
    }

    func isInteractionStale(now: Date, threshold: TimeInterval) -> Bool {
        now.timeIntervalSince(lastInteractionAt) >= threshold
    }

    private static func stableOrdinal(for id: UUID) -> Int32 {
        var hash: UInt32 = 2_166_136_261
        for byte in id.uuidString.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return Int32(bitPattern: hash)
    }
}

/// Immutable whole-terminal render payload. Kept core-only: no Project Tracker,
/// message ledger, or plugin-specific dependencies belong in this boundary.
struct TerminalRenderSnapshot: Equatable, Sendable {
    let activeChannelID: UUID?
    let channels: [ChannelRenderSnapshot]
    let capturedAt: Date

    @MainActor
    init(channels: [any ChannelController], activeChannelID: UUID?, capturedAt: Date = Date()) {
        self.activeChannelID = activeChannelID
        self.capturedAt = capturedAt
        self.channels = channels.map { channel in
            ChannelRenderSnapshot(
                channel: channel,
                isActive: channel.channelId == activeChannelID,
                capturedAt: capturedAt
            )
        }
    }

    init(activeChannelID: UUID?, channels: [ChannelRenderSnapshot], capturedAt: Date = Date()) {
        self.activeChannelID = activeChannelID
        self.channels = channels
        self.capturedAt = capturedAt
    }

    var activeChannel: ChannelRenderSnapshot? {
        guard let activeChannelID else { return nil }
        return channels.first { $0.channelID == activeChannelID }
    }
}
