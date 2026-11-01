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

struct ChannelNavigationContext: Equatable, Sendable {
    let typeLabel: String
    let identityLabel: String?
    let locationPath: String?

    var detailText: String {
        [typeLabel, identityLabel, compactLocation]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " • ")
    }

    var accessibilityDescription: String {
        [typeLabel, identityLabel, locationPath]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: ", ")
    }

    private var compactLocation: String? {
        guard let locationPath, !locationPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: locationPath).standardizedFileURL
        let components = url.pathComponents.filter { $0 != "/" }
        guard !components.isEmpty else { return "/" }
        return components.last
    }
}
