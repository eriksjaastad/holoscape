import XCTest
@testable import Holoscape

final class V2ModelTests: XCTestCase {

    // MARK: - ConnectionType V2

    func testMCPConnectionTypeRoundTrip() throws {
        let profile = SessionProfile(label: "CEO", connection: .mcp, command: "", directory: "", endpoint: "http://localhost:8080/mcp/ceo")
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(SessionProfile.self, from: data)
        XCTAssertEqual(decoded.connection, .mcp)
        XCTAssertEqual(decoded.endpoint, "http://localhost:8080/mcp/ceo")
    }

    func testAgentChatConnectionTypeRoundTrip() throws {
        let profile = SessionProfile(label: "Group Chat", connection: .agentChat, command: "", directory: "", apiURL: "https://chat.example.com", apiKeyEnv: "AGENT_CHAT_API_KEY")
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(SessionProfile.self, from: data)
        XCTAssertEqual(decoded.connection, .agentChat)
        XCTAssertEqual(decoded.apiURL, "https://chat.example.com")
        XCTAssertEqual(decoded.apiKeyEnv, "AGENT_CHAT_API_KEY")
    }

    func testV15ProfileStillDecodesWithV2Fields() throws {
        let json = """
        {"label":"architect","connection":"ssh","command":"claude","directory":"~/projects","host":"MacBook.local","user":"erik"}
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(SessionProfile.self, from: json)
        XCTAssertEqual(profile.label, "architect")
        XCTAssertNil(profile.endpoint)
        XCTAssertNil(profile.apiURL)
        XCTAssertNil(profile.apiKeyEnv)
    }

    // MARK: - ChannelType V2

    func testMCPChannelTypeRoundTrip() throws {
        let meta = ChannelMetadata(id: UUID(), type: .mcp, role: "CEO", endpoint: "http://localhost:8080/mcp/ceo")
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ChannelMetadata.self, from: data)
        XCTAssertEqual(decoded.type, .mcp)
        XCTAssertEqual(decoded.endpoint, "http://localhost:8080/mcp/ceo")
    }

    // MARK: - Config V2 Fields

    func testAppearanceConfigThemeFields() throws {
        var config = HoloscapeConfig.default
        config.appearance.themeName = "Dracula"
        config.appearance.themeOverrides = ["backgroundColor": "#000000"]
        config.showTimestamps = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HoloscapeConfig.self, from: data)

        XCTAssertEqual(decoded.appearance.themeName, "Dracula")
        XCTAssertEqual(decoded.appearance.themeOverrides?["backgroundColor"], "#000000")
        XCTAssertEqual(decoded.showTimestamps, true)
    }

    func testV15ConfigBackwardCompat() throws {
        // V1.5 config without V2 fields should decode fine
        let json = """
        {
            "appearance": {"backgroundColor":"#1a1a2e","transparency":1.0,"fontFamily":"SF Mono","fontSize":13.0},
            "channels": [],
            "sidebarExpanded": true
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(HoloscapeConfig.self, from: json)
        XCTAssertNil(config.showTimestamps)
        XCTAssertNil(config.appearance.themeName)
        XCTAssertNil(config.appearance.themeOverrides)
        XCTAssertEqual(config.sidebarExpanded, true)
    }

    // MARK: - ChannelMetadata V2 Fields

    func testChannelMetadataV2RoundTrip() throws {
        let meta = ChannelMetadata(
            id: UUID(), type: .groupChat, role: "Chat",
            apiURL: "https://chat.example.com", apiKeyEnv: "MY_KEY"
        )
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ChannelMetadata.self, from: data)
        XCTAssertEqual(decoded.apiURL, "https://chat.example.com")
        XCTAssertEqual(decoded.apiKeyEnv, "MY_KEY")
    }

    func testChannelMetadataV15CompatNilV2Fields() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","type":"ssh","role":"architect","host":"MacBook.local","user":"erik","command":"claude"}
        """.data(using: .utf8)!
        let meta = try JSONDecoder().decode(ChannelMetadata.self, from: json)
        XCTAssertNil(meta.endpoint)
        XCTAssertNil(meta.apiURL)
        XCTAssertNil(meta.apiKeyEnv)
    }

    // MARK: - All ConnectionType cases round-trip

    func testAllConnectionTypesRoundTrip() throws {
        let cases: [ConnectionType] = [.local, .ssh, .mcp, .agentChat]
        for connType in cases {
            let data = try JSONEncoder().encode(connType)
            let decoded = try JSONDecoder().decode(ConnectionType.self, from: data)
            XCTAssertEqual(connType, decoded, "Round-trip failed for \(connType)")
        }
    }
}
