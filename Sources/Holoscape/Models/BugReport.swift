import Foundation

struct BugReport: Codable, Sendable {
    let channelName: String
    let channelType: ChannelType
    let lastOutputLines: [String]
    let timestamp: Date
    let macOSVersion: String
    let description: String

    // V4 fields
    let appVersion: String?
    let hardwareModel: String?
    let allChannelStates: [ChannelStateInfo]?
    let appearanceConfig: String?
    let splitLayout: String?
    let uptime: TimeInterval?
    let historyBuffer: HistorySnapshot?
    let screenshotData: Data?
}
