import XCTest
@testable import Holoscape

final class SessionProfileTests: XCTestCase {

    // MARK: - Codable Round-Trip

    func testLocalProfileRoundTrip() throws {
        let profile = SessionProfile(label: "mini-claude", connection: .local, command: "claude", directory: "~")
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(SessionProfile.self, from: data)
        XCTAssertEqual(profile, decoded)
    }

    func testSSHProfileWithHostRoundTrip() throws {
        let profile = SessionProfile(label: "architect", connection: .ssh, command: "claude", directory: "~/projects", host: "MacBook.local", user: "erik")
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(SessionProfile.self, from: data)
        XCTAssertEqual(profile, decoded)
    }

    func testSSHProfileWithoutHostDecodesNil() throws {
        let json = """
        {"label":"test","connection":"ssh","command":"claude","directory":"~"}
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(SessionProfile.self, from: json)
        XCTAssertNil(profile.host)
        XCTAssertNil(profile.user)
    }

    // MARK: - SSH Defaults Resolution

    func testResolvedFillsMissingHost() {
        let profile = SessionProfile(label: "test", connection: .ssh, command: "claude", directory: "~", host: nil, user: nil)
        let defaults = SSHDefaults(host: "MacBook.local", user: "erik")
        let resolved = profile.resolved(with: defaults)
        XCTAssertEqual(resolved.host, "MacBook.local")
        XCTAssertEqual(resolved.user, "erik")
    }

    func testResolvedPreservesExistingHost() {
        let profile = SessionProfile(label: "test", connection: .ssh, command: "claude", directory: "~", host: "custom.host", user: "custom")
        let defaults = SSHDefaults(host: "MacBook.local", user: "erik")
        let resolved = profile.resolved(with: defaults)
        XCTAssertEqual(resolved.host, "custom.host")
        XCTAssertEqual(resolved.user, "custom")
    }

    func testResolvedFillsEmptyHost() {
        let profile = SessionProfile(label: "test", connection: .ssh, command: "claude", directory: "~", host: "", user: "")
        let defaults = SSHDefaults(host: "MacBook.local", user: "erik")
        let resolved = profile.resolved(with: defaults)
        XCTAssertEqual(resolved.host, "MacBook.local")
        XCTAssertEqual(resolved.user, "erik")
    }

    func testResolvedNoOpForLocalConnection() {
        let profile = SessionProfile(label: "shell", connection: .local, command: "/bin/zsh", directory: "~")
        let defaults = SSHDefaults(host: "MacBook.local", user: "erik")
        let resolved = profile.resolved(with: defaults)
        XCTAssertNil(resolved.host)
        XCTAssertNil(resolved.user)
    }

    func testResolvedNoOpWithNilDefaults() {
        let profile = SessionProfile(label: "test", connection: .ssh, command: "claude", directory: "~", host: nil, user: nil)
        let resolved = profile.resolved(with: nil)
        XCTAssertNil(resolved.host)
        XCTAssertNil(resolved.user)
    }

    func testResolvedPreservesNonSSHFields() {
        let profile = SessionProfile(label: "architect", connection: .ssh, command: "claude", directory: "~/projects", host: nil, user: nil)
        let defaults = SSHDefaults(host: "MacBook.local", user: "erik")
        let resolved = profile.resolved(with: defaults)
        XCTAssertEqual(resolved.label, "architect")
        XCTAssertEqual(resolved.connection, .ssh)
        XCTAssertEqual(resolved.command, "claude")
        XCTAssertEqual(resolved.directory, "~/projects")
    }

    // MARK: - V1 Config Backward Compatibility

    func testV1ConfigDecodesWithoutV15Fields() throws {
        let json = """
        {
            "appearance": {
                "backgroundColor": "#1a1a2e",
                "transparency": 1.0,
                "fontFamily": "SF Mono",
                "fontSize": 13.0
            },
            "channels": []
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(HoloscapeConfig.self, from: json)
        XCTAssertNil(config.sessionProfiles)
        XCTAssertNil(config.sshDefaults)
        XCTAssertNil(config.projectDiscovery)
        XCTAssertNil(config.sidebarExpanded)
        XCTAssertNil(config.recentSessions)
        XCTAssertEqual(config.channels, [])
    }

    func testV15ConfigRoundTrip() throws {
        var config = HoloscapeConfig.default
        config.sessionProfiles = [
            SessionProfile(label: "mini-claude", connection: .local, command: "claude", directory: "~"),
            SessionProfile(label: "architect", connection: .ssh, command: "claude", directory: "~/projects", host: "MacBook.local", user: "erik"),
        ]
        config.sshDefaults = SSHDefaults(host: "MacBook.local", user: "erik")
        config.projectDiscovery = ProjectDiscoveryConfig(enabled: true, root: "~/projects", connection: "ssh", command: "claude")
        config.sidebarExpanded = true
        config.recentSessions = [RecentSession(label: "mini-claude", timestamp: Date(timeIntervalSince1970: 1000))]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HoloscapeConfig.self, from: data)

        XCTAssertEqual(config, decoded)
    }

    // MARK: - ChannelMetadata SSH Fields

    func testChannelMetadataSSHRoundTrip() throws {
        let meta = ChannelMetadata(
            id: UUID(),
            type: .ssh,
            role: "architect",
            host: "MacBook.local",
            user: "erik",
            command: "claude"
        )
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(ChannelMetadata.self, from: data)
        XCTAssertEqual(meta, decoded)
        XCTAssertEqual(decoded.host, "MacBook.local")
        XCTAssertEqual(decoded.user, "erik")
        XCTAssertEqual(decoded.command, "claude")
    }

    func testChannelMetadataV1CompatNilSSHFields() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","type":"shell","role":"Shell"}
        """.data(using: .utf8)!
        let meta = try JSONDecoder().decode(ChannelMetadata.self, from: json)
        XCTAssertNil(meta.host)
        XCTAssertNil(meta.user)
        XCTAssertNil(meta.command)
    }
}
