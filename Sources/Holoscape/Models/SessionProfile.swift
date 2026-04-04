import Foundation

enum ConnectionType: String, Codable, Sendable {
    case local
    case ssh
}

struct SessionProfile: Codable, Equatable, Sendable {
    var label: String
    var connection: ConnectionType
    var command: String
    var directory: String
    var host: String?
    var user: String?

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
