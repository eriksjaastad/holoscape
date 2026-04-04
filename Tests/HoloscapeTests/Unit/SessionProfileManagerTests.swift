import XCTest
@testable import Holoscape

final class SessionProfileManagerTests: XCTestCase {

    // MARK: - Discovery Profile Generation

    @MainActor
    func testProfilesFromDirectoryNames() {
        let configService = ConfigService()
        let discovery = ProjectDiscoveryService(configService: configService)
        let defaults = SSHDefaults(host: "MacBook.local", user: "erik")
        let config = ProjectDiscoveryConfig(enabled: true, root: "~/projects", connection: "ssh", command: "claude")

        let profiles = discovery.profilesFromDirectoryNames(["holoscape", "auxesis", "tracker"], discovery: config, defaults: defaults)

        XCTAssertEqual(profiles.count, 3)
        XCTAssertEqual(profiles[0].label, "holoscape")
        XCTAssertEqual(profiles[0].connection, .ssh)
        XCTAssertEqual(profiles[0].command, "claude")
        XCTAssertEqual(profiles[0].directory, "~/projects/holoscape")
        XCTAssertEqual(profiles[0].host, "MacBook.local")
        XCTAssertEqual(profiles[0].user, "erik")

        XCTAssertEqual(profiles[1].label, "auxesis")
        XCTAssertEqual(profiles[2].label, "tracker")
    }

    @MainActor
    func testProfilesFromEmptyDirectoryList() {
        let configService = ConfigService()
        let discovery = ProjectDiscoveryService(configService: configService)
        let defaults = SSHDefaults(host: "MacBook.local", user: "erik")
        let config = ProjectDiscoveryConfig(enabled: true, root: "~/projects", connection: "ssh", command: "claude")

        let profiles = discovery.profilesFromDirectoryNames([], discovery: config, defaults: defaults)
        XCTAssertTrue(profiles.isEmpty)
    }

    // MARK: - Resolve

    @MainActor
    func testResolvePreconfiguredProfile() {
        let configService = ConfigService()
        let discoveryService = ProjectDiscoveryService(configService: configService)
        let manager = SessionProfileManager(configService: configService, discoveryService: discoveryService)

        // Save a config with a preconfigured profile
        var config = HoloscapeConfig.default
        config.sessionProfiles = [
            SessionProfile(label: "mini-claude", connection: .local, command: "claude", directory: "~"),
        ]
        configService.save(config)

        let resolved = manager.resolve(label: "mini-claude")
        XCTAssertEqual(resolved.label, "mini-claude")
        XCTAssertEqual(resolved.connection, .local)
        XCTAssertEqual(resolved.command, "claude")
    }

    @MainActor
    func testResolveUnknownLabelCreatesSSHProject() {
        let configService = ConfigService()
        let discoveryService = ProjectDiscoveryService(configService: configService)
        let manager = SessionProfileManager(configService: configService, discoveryService: discoveryService)

        var config = HoloscapeConfig.default
        config.sshDefaults = SSHDefaults(host: "MacBook.local", user: "erik")
        config.projectDiscovery = ProjectDiscoveryConfig(enabled: true, root: "~/projects", connection: "ssh", command: "claude")
        configService.save(config)

        let resolved = manager.resolve(label: "new-project")
        XCTAssertEqual(resolved.label, "new-project")
        XCTAssertEqual(resolved.connection, .ssh)
        XCTAssertEqual(resolved.directory, "~/projects/new-project")
        XCTAssertEqual(resolved.host, "MacBook.local")
        XCTAssertEqual(resolved.user, "erik")
    }

    // MARK: - Recent Sessions

    @MainActor
    func testRecordRecentSessionPrependsAndDeduplicates() {
        let configService = ConfigService()
        let discoveryService = ProjectDiscoveryService(configService: configService)
        let manager = SessionProfileManager(configService: configService, discoveryService: discoveryService)

        // Start clean
        configService.save(HoloscapeConfig.default)

        manager.recordRecentSession(label: "alpha")
        manager.recordRecentSession(label: "beta")
        manager.recordRecentSession(label: "alpha")  // should deduplicate

        let config = configService.load()
        let recent = config.recentSessions ?? []
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent[0].label, "alpha")  // most recent first
        XCTAssertEqual(recent[1].label, "beta")
    }

    @MainActor
    func testRecordRecentSessionCapsAt20() {
        let configService = ConfigService()
        let discoveryService = ProjectDiscoveryService(configService: configService)
        let manager = SessionProfileManager(configService: configService, discoveryService: discoveryService)

        configService.save(HoloscapeConfig.default)

        for i in 0..<25 {
            manager.recordRecentSession(label: "session-\(i)")
        }

        let config = configService.load()
        let recent = config.recentSessions ?? []
        XCTAssertEqual(recent.count, 20)
        XCTAssertEqual(recent[0].label, "session-24")  // most recent first
    }
}
