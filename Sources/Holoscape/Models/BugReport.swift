import Foundation

struct BugReport: Codable, Sendable {
    let channelName: String
    let channelType: ChannelType
    let lastOutputLines: [String]
    let timestamp: Date
    let macOSVersion: String
    let description: String
}
