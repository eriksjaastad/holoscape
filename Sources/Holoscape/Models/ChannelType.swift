import Foundation

enum ChannelType: String, Codable, Sendable {
    case shell
    case agentDirect
    case agentAPI
    case groupChat
    case ssh
    case mcp
    case bridge
}
