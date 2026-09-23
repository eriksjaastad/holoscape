import Foundation

struct ChannelMetadata: Codable, Equatable, Sendable {
    let id: UUID
    let type: ChannelType
    let role: String
    let context: String?
    let instanceNumber: Int?
    let workingDirectory: String?
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

    init(id: UUID, type: ChannelType, role: String, context: String? = nil,
         instanceNumber: Int? = nil, workingDirectory: String? = nil,
         host: String? = nil, user: String? = nil, command: String? = nil,
         endpoint: String? = nil, apiURL: String? = nil, apiKeyEnv: String? = nil,
         pinnedAt: Date? = nil, persistentState: PersistentChannelState? = nil,
         brokerSessionID: BrokerSessionID? = nil,
         staleBrokerSessionID: BrokerSessionID? = nil) {
        self.id = id
        self.type = type
        self.role = role
        self.context = context
        self.instanceNumber = instanceNumber
        self.workingDirectory = workingDirectory
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
    }
}
