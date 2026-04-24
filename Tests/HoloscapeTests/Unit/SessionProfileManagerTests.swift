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
    func testResolveBuiltInClaudeProfileOpensLocalClaudeAgent() {
        let configService = ConfigService()
        let discoveryService = ProjectDiscoveryService(configService: configService)
        let manager = SessionProfileManager(configService: configService, discoveryService: discoveryService)

        configService.save(HoloscapeConfig.default)

        let resolved = manager.resolve(label: "Claude")
        XCTAssertEqual(resolved.label, "Claude")
        XCTAssertEqual(resolved.connection, .local)
        XCTAssertEqual(resolved.command, "claude")
        XCTAssertEqual(resolved.directory, DefaultWorkingDirectory.preferredPath)
    }

    @MainActor
    func testResolveBuiltInClaudeProfileIgnoresCaseAndWhitespace() {
        let configService = ConfigService()
        let discoveryService = ProjectDiscoveryService(configService: configService)
        let manager = SessionProfileManager(configService: configService, discoveryService: discoveryService)

        configService.save(HoloscapeConfig.default)

        let resolved = manager.resolve(label: " claude ")
        XCTAssertEqual(resolved.label, "Claude")
        XCTAssertEqual(resolved.connection, .local)
        XCTAssertEqual(resolved.command, "claude")
    }

    @MainActor
    func testResolveClaudeProjectOpensClaudeInProjectDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-session-profiles-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("holoscape", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let configService = ConfigService()
        let discoveryService = ProjectDiscoveryService(configService: configService)
        let manager = SessionProfileManager(configService: configService, discoveryService: discoveryService)

        var config = HoloscapeConfig.default
        config.projectDiscovery = ProjectDiscoveryConfig(enabled: true, root: root.path, connection: "local", command: "claude")
        configService.save(config)

        let resolved = manager.resolve(label: "claude holoscape")
        XCTAssertEqual(resolved.label, "Claude-holoscape")
        XCTAssertEqual(resolved.connection, .local)
        XCTAssertEqual(resolved.command, "claude")
        XCTAssertEqual(resolved.directory, project.standardizedFileURL.path)
    }

    @MainActor
    func testResolveDirectSSHCommandCreatesSSHProfile() {
        let configService = ConfigService()
        let discoveryService = ProjectDiscoveryService(configService: configService)
        let manager = SessionProfileManager(configService: configService, discoveryService: discoveryService)

        configService.save(HoloscapeConfig.default)

        let resolved = manager.resolve(label: "ssh erik@eriks-mac-mini.local")
        XCTAssertEqual(resolved.label, "eriks-mac-mini.local")
        XCTAssertEqual(resolved.connection, .ssh)
        XCTAssertEqual(resolved.host, "eriks-mac-mini.local")
        XCTAssertEqual(resolved.user, "erik")
        XCTAssertEqual(resolved.directory, "~")
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

    @MainActor
    func testResolveUnknownLabelWithoutSSHDefaultsCreatesLocalProjectSession() {
        let configService = ConfigService()
        let discoveryService = ProjectDiscoveryService(configService: configService)
        let manager = SessionProfileManager(configService: configService, discoveryService: discoveryService)

        var config = HoloscapeConfig.default
        config.projectDiscovery = ProjectDiscoveryConfig(enabled: true, root: "~/projects", connection: "ssh", command: "claude")
        configService.save(config)

        let resolved = manager.resolve(label: "not-a-configured-remote")
        XCTAssertEqual(resolved.label, "not-a-configured-remote")
        XCTAssertEqual(resolved.connection, .local)
        XCTAssertEqual(resolved.command, "/bin/zsh")
        XCTAssertFalse(resolved.directory.isEmpty)
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
