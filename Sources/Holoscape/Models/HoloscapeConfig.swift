import Foundation

struct HoloscapeConfig: Codable, Equatable, Sendable {
    var appearance: AppearanceConfig
    var channels: [ChannelMetadata]
    var lastLaunchTimestamp: Date?

    // V1.5 fields — all Optional for backward compatibility with V1 configs
    var sessionProfiles: [SessionProfile]?
    var sshDefaults: SSHDefaults?
    var projectDiscovery: ProjectDiscoveryConfig?
    var sidebarExpanded: Bool?
    var recentSessions: [RecentSession]?

    // V2 fields
    var showTimestamps: Bool?

    // V3 fields
    var notifications: NotificationConfig?
    var splitLayout: SplitLayoutConfig?

    // Chrome skinning fields (optional for backward compat)
    var chromeRegions: ChromeRegionState?

    static let `default` = HoloscapeConfig(
        appearance: AppearanceConfig.default,
        channels: [],
        lastLaunchTimestamp: nil,
        sessionProfiles: nil,
        sshDefaults: nil,
        projectDiscovery: nil,
        sidebarExpanded: nil,
        recentSessions: nil
    )
}

struct AppearanceConfig: Codable, Equatable, Sendable {
    var backgroundColor: String
    var transparency: Double
    var fontFamily: String
    var fontSize: Double
    var ansiColors: [String: String]?
    var themeName: String?
    var themeOverrides: [String: String]?
    var skinName: String?
    var customShaderPath: String?

    static let `default` = AppearanceConfig(
        backgroundColor: "#1a1a2e",
        transparency: 1.0,
        fontFamily: "SF Mono",
        fontSize: 13.0,
        ansiColors: nil
    )
}

/// Runtime state for the four collapsible chrome regions plus the
/// active density mode. Persisted in HoloscapeConfig so the layout
/// survives across app launches. Optional on the outer config for
/// backward compatibility with pre-skinning persisted state.
struct ChromeRegionState: Codable, Equatable, Sendable {
    var topCollapsed: Bool
    var rightCollapsed: Bool
    var bottomCollapsed: Bool
    var leftCollapsed: Bool
    /// One of "full", "minimal", "off". Defaults to "full" when absent.
    var densityMode: String?

    static let `default` = ChromeRegionState(
        topCollapsed: false,
        rightCollapsed: false,
        bottomCollapsed: false,
        leftCollapsed: false,
        densityMode: "full"
    )
}
