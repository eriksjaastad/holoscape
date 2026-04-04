import Foundation

struct HoloscapeConfig: Codable, Equatable, Sendable {
    var appearance: AppearanceConfig
    var channels: [ChannelMetadata]
    var lastLaunchTimestamp: Date?

    static let `default` = HoloscapeConfig(
        appearance: .default,
        channels: [],
        lastLaunchTimestamp: nil
    )
}

struct AppearanceConfig: Codable, Equatable, Sendable {
    var backgroundColor: String
    var transparency: Double
    var fontFamily: String
    var fontSize: Double
    var ansiColors: [String: String]?

    static let `default` = AppearanceConfig(
        backgroundColor: "#1a1a2e",
        transparency: 1.0,
        fontFamily: "SF Mono",
        fontSize: 13.0,
        ansiColors: nil
    )
}
