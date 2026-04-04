import Foundation

struct RecentSession: Codable, Equatable, Sendable {
    var label: String
    var timestamp: Date
}
