import Foundation

struct ChannelMetadata: Codable, Equatable, Sendable {
    let id: UUID
    let type: ChannelType
    let role: String
    let context: String?
    let instanceNumber: Int?
    let workingDirectory: String?
}
