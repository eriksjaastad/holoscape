import Foundation

enum ConnectionType: String, Codable, Sendable {
    case local
    case ssh
    case mcp
    case agentChat
}

struct SessionProfile: Codable, Equatable, Sendable {
    var label: String
    var connection: ConnectionType
    var command: String
    var directory: String
    var host: String?
    var user: String?
    var endpoint: String?     // MCP server URL
    var apiURL: String?       // Agent Chat API URL
    var apiKeyEnv: String?    // Env var name for Agent Chat API key

    /// Fill in missing SSH fields from defaults.
    func resolved(with defaults: SSHDefaults?) -> SessionProfile {
        guard connection == .ssh, let defaults else { return self }
        var copy = self
        if copy.host == nil || copy.host?.isEmpty == true {
            copy.host = defaults.host
        }
        if copy.user == nil || copy.user?.isEmpty == true {
            copy.user = defaults.user
        }
        return copy
    }
}
