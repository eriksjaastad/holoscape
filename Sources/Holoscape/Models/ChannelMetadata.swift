import Foundation

struct ChannelMetadata: Codable, Equatable, Sendable {
    let id: UUID
    let type: ChannelType
    let role: String
    let context: String?
    let instanceNumber: Int?
    /// Whether the agent launch label is an exact presentation value rather than
    /// input for role abbreviation. Nil identifies legacy saved metadata.
    let useRawLabel: Bool?
    let workingDirectory: String?
    let customLabel: String?
    let host: String?
    let user: String?
    let command: String?
    let endpoint: String?     // MCP
    let apiURL: String?       // Agent Chat
    let apiKeyEnv: String?    // Agent Chat
    let pinnedAt: Date?       // Tab pinning
    let persistentState: PersistentChannelState?
    let brokerSessionID: BrokerSessionID? // Durable broker session for UI restore
    /// Identity of a broker session this tab could not reattach because the
    /// broker no longer owns it. Persisted only while the tab is stale and
    /// waiting for an explicit recreate, so recovery guidance (and the tab's
    /// association with that session) survives relaunch/restore.
    let staleBrokerSessionID: BrokerSessionID?
    /// Retry-only cleanup authority for already-presented final broker output.
    let pendingExitedOutputRetirement: BrokerExitedOutputRetirement?
    /// Durable presentation tombstone for a tab the user already closed while
    /// completed-session cleanup still owns retryable broker authority. These
    /// records restore only to finish cleanup and must never reappear as tabs.
    let closeTombstone: Bool?

    init(id: UUID, type: ChannelType, role: String, context: String? = nil,
         instanceNumber: Int? = nil, useRawLabel: Bool? = nil, workingDirectory: String? = nil,
         customLabel: String? = nil,
         host: String? = nil, user: String? = nil, command: String? = nil,
         endpoint: String? = nil, apiURL: String? = nil, apiKeyEnv: String? = nil,
         pinnedAt: Date? = nil, persistentState: PersistentChannelState? = nil,
         brokerSessionID: BrokerSessionID? = nil,
         staleBrokerSessionID: BrokerSessionID? = nil,
         pendingExitedOutputRetirement: BrokerExitedOutputRetirement? = nil,
         closeTombstone: Bool? = nil) {
        self.id = id
        self.type = type
        self.role = role
        self.context = context
        self.instanceNumber = instanceNumber
        self.useRawLabel = useRawLabel
        self.workingDirectory = workingDirectory
        self.customLabel = customLabel
        self.host = host
        self.user = user
        self.command = command
        self.endpoint = endpoint
        self.apiURL = apiURL
        self.apiKeyEnv = apiKeyEnv
        self.pinnedAt = pinnedAt
        self.persistentState = persistentState
        self.brokerSessionID = brokerSessionID
        self.staleBrokerSessionID = staleBrokerSessionID
        self.pendingExitedOutputRetirement = pendingExitedOutputRetirement
        self.closeTombstone = closeTombstone
    }
}
