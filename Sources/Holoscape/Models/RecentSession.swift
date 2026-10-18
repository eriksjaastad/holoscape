import Foundation

struct RecentSession: Codable, Equatable, Sendable {
    var label: String
    var timestamp: Date
    /// Stored so reopening a recent session does not resolve by display label.
    /// Nil is retained for backward-compatible legacy entries.
    var profile: SessionProfile?

    init(label: String, timestamp: Date, profile: SessionProfile? = nil) {
        self.label = label
        self.timestamp = timestamp
        self.profile = profile
    }
}
