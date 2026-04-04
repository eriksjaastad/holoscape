import Foundation

struct CrashReport: Codable, Sendable {
    let crashTrace: String
    let lastChannelState: [ChannelMetadata]?
    let timestamp: Date
    let macOSVersion: String
}
