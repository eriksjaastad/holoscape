import Foundation

struct SplitLayoutConfig: Codable, Equatable, Sendable {
    var panes: [PaneConfig]
    var activePaneId: UUID?

    static let `default` = SplitLayoutConfig(panes: [], activePaneId: nil)
}

struct PaneConfig: Codable, Equatable, Sendable {
    let paneId: UUID
    let channelId: UUID
}
