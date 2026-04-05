import XCTest
@testable import Holoscape

final class V3ModelTests: XCTestCase {

    // MARK: - ConnectionType & ChannelType

    func testBridgeConnectionTypeRoundTrip() throws {
        let profile = SessionProfile(label: "Bridge", connection: .bridge, command: "", directory: "")
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(SessionProfile.self, from: data)
        XCTAssertEqual(decoded.connection, .bridge)
    }

    func testBridgeChannelTypeRoundTrip() throws {
        let meta = ChannelMetadata(id: UUID(), type: .bridge, role: "Bridge")
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ChannelMetadata.self, from: data)
        XCTAssertEqual(decoded.type, .bridge)
    }

    func testAllConnectionTypesIncludingBridge() throws {
        let cases: [ConnectionType] = [.local, .ssh, .mcp, .agentChat, .bridge]
        for ct in cases {
            let data = try JSONEncoder().encode(ct)
            let decoded = try JSONDecoder().decode(ConnectionType.self, from: data)
            XCTAssertEqual(ct, decoded)
        }
    }

    // MARK: - NotificationConfig

    func testNotificationConfigRoundTrip() throws {
        let config = NotificationConfig.default
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(NotificationConfig.self, from: data)
        XCTAssertEqual(config, decoded)
    }

    func testNotificationIsEnabledForAgent() {
        let config = NotificationConfig.default
        XCTAssertTrue(config.isEnabled(for: .agentDirect))
        XCTAssertTrue(config.isEnabled(for: .ssh))
        XCTAssertFalse(config.isEnabled(for: .shell))
        XCTAssertFalse(config.isEnabled(for: .bridge))
    }

    func testNotificationGlobalDisable() {
        let config = NotificationConfig(enabled: false, perChannelType: ["agent": true])
        XCTAssertFalse(config.isEnabled(for: .agentDirect))
    }

    // MARK: - SplitLayoutConfig

    func testSplitLayoutRoundTrip() throws {
        let pane = PaneConfig(paneId: UUID(), channelId: UUID())
        let layout = SplitLayoutConfig(panes: [pane], activePaneId: pane.paneId)
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(SplitLayoutConfig.self, from: data)
        XCTAssertEqual(layout, decoded)
    }

    // MARK: - SkinDefinition

    func testSkinDefinitionRoundTrip() throws {
        let skin = SkinDefinition(
            windowBackground: "#282a36",
            textForeground: "#f8f8f2",
            ansiColors: Array(repeating: "#000000", count: 16),
            windowBackgroundImage: "bg.png"
        )
        let data = try JSONEncoder().encode(skin)
        let decoded = try JSONDecoder().decode(SkinDefinition.self, from: data)
        XCTAssertEqual(skin, decoded)
    }

    // MARK: - ChannelMetadata pinnedAt

    func testPinnedAtRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1000)
        let meta = ChannelMetadata(id: UUID(), type: .shell, role: "Shell", pinnedAt: date)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(meta)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ChannelMetadata.self, from: data)
        XCTAssertEqual(decoded.pinnedAt, date)
    }

    func testV2MetadataBackwardCompatNoPinnedAt() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","type":"shell","role":"Shell"}
        """.data(using: .utf8)!
        let meta = try JSONDecoder().decode(ChannelMetadata.self, from: json)
        XCTAssertNil(meta.pinnedAt)
    }

    // MARK: - HoloscapeConfig V3 fields

    func testV3ConfigFieldsRoundTrip() throws {
        var config = HoloscapeConfig.default
        config.notifications = .default
        config.splitLayout = SplitLayoutConfig(panes: [PaneConfig(paneId: UUID(), channelId: UUID())], activePaneId: nil)
        config.appearance.skinName = "Dracula"

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HoloscapeConfig.self, from: data)

        XCTAssertEqual(decoded.notifications?.enabled, true)
        XCTAssertEqual(decoded.appearance.skinName, "Dracula")
        XCTAssertEqual(decoded.splitLayout?.panes.count, 1)
    }

    func testV2ConfigBackwardCompatNoV3Fields() throws {
        let json = """
        {
            "appearance": {"backgroundColor":"#1a1a2e","transparency":1.0,"fontFamily":"SF Mono","fontSize":13.0},
            "channels": [],
            "showTimestamps": true
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(HoloscapeConfig.self, from: json)
        XCTAssertNil(config.notifications)
        XCTAssertNil(config.splitLayout)
        XCTAssertNil(config.appearance.skinName)
        XCTAssertEqual(config.showTimestamps, true)
    }
}
