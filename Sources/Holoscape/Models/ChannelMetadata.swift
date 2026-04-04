import Foundation

struct ChannelMetadata: Codable, Equatable, Sendable {
    let id: UUID
    let type: ChannelType
    let role: String
    let context: String?
    let instanceNumber: Int?
    let workingDirectory: String?
    let host: String?
    let user: String?
    let command: String?

    init(id: UUID, type: ChannelType, role: String, context: String? = nil,
         instanceNumber: Int? = nil, workingDirectory: String? = nil,
         host: String? = nil, user: String? = nil, command: String? = nil) {
        self.id = id
        self.type = type
        self.role = role
        self.context = context
        self.instanceNumber = instanceNumber
        self.workingDirectory = workingDirectory
        self.host = host
        self.user = user
        self.command = command
    }
}
