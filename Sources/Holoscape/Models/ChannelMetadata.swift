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

    init(id: UUID, type: ChannelType, role: String, context: String? = nil,
         instanceNumber: Int? = nil, workingDirectory: String? = nil,
         host: String? = nil, user: String? = nil, command: String? = nil,
         endpoint: String? = nil, apiURL: String? = nil, apiKeyEnv: String? = nil) {
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
    }
}
