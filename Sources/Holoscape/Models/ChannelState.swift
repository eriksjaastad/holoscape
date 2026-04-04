import Foundation

enum ChannelState: String, Codable, Sendable {
    case active
    case disconnected
    case connecting
}
