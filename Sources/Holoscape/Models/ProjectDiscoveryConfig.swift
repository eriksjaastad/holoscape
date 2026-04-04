import Foundation

struct ProjectDiscoveryConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    var root: String
    var connection: String
    var command: String

    static let `default` = ProjectDiscoveryConfig(
        enabled: false,
        root: "~/projects",
        connection: "ssh",
        command: "claude"
    )
}
