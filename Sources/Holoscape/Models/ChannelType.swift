import Foundation

enum ChannelType: String, Codable, Sendable {
    case shell
    case agentDirect
    case agentAPI
    case groupChat
    case ssh
    case mcp
    case bridge

    var sidebarPrefix: String {
        switch self {
        case .shell: return "Shell"
        case .agentDirect, .agentAPI: return "Agent"
        case .groupChat: return "GroupChat"
        case .ssh: return "SSH"
        case .mcp: return "MCP"
        case .bridge: return "Bridge"
        }
    }
}
