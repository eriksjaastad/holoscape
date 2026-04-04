import Foundation

struct SSHDefaults: Codable, Equatable, Sendable {
    var host: String
    var user: String

    static let `default` = SSHDefaults(host: "", user: "")
}
