import Foundation

struct NotificationConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    var perChannelType: [String: Bool]?

    static let `default` = NotificationConfig(
        enabled: true,
        perChannelType: [
            "shell": false,
            "agent": true,
            "ssh": true,
            "mcp": true,
            "groupChat": true,
        ]
    )

    func isEnabled(for channelType: ChannelType) -> Bool {
        guard enabled else { return false }
        let key: String
        switch channelType {
        case .shell: key = "shell"
        case .agentDirect, .agentAPI: key = "agent"
        case .ssh: key = "ssh"
        case .mcp: key = "mcp"
        case .groupChat: key = "groupChat"
        case .bridge: return false
        }
        return perChannelType?[key] ?? true
    }
}
