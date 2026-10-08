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

    @MainActor
    func testLocalProjectDiscoveryListsOnlyDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-local-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("auxesis", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("holoscape", isDirectory: true), withIntermediateDirectories: true)
        try "not a project".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let discovery = ProjectDiscoveryService(configService: ConfigService())
        let profiles = try discovery.profilesFromLocalProjectRoot(
            ProjectDiscoveryConfig(enabled: true, root: root.path, connection: "local", command: "claude")
        )

        XCTAssertEqual(profiles.map(\.label), ["auxesis", "holoscape"])
        XCTAssertEqual(profiles.map(\.connection), [.local, .local])
        XCTAssertEqual(profiles.map(\.command), ["/bin/zsh", "/bin/zsh"])
        XCTAssertEqual(profiles[0].directory, root.appendingPathComponent("auxesis", isDirectory: true).standardizedFileURL.path)
    }

    func testRemoteDirectoryListingParsesSortedNonemptyLines() async throws {
        let script = try makeDiscoveryScript("""
        printf 'zeta\\n\\n alpha \\n'
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let directories = try await ProjectDiscoveryService.listDirectories(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path],
            timeout: 1
        )

        XCTAssertEqual(directories, ["alpha", "zeta"])
    }

    func testRemoteDirectoryListingCommandTreatsMetacharactersAndQuotesAsPathData() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-remote-command-\(UUID().uuidString)", isDirectory: true)
        let rootName = "-projects; touch escaped; printf 'ignored'"
        let root = workspace.appendingPathComponent(rootName, isDirectory: true)
        let sentinel = workspace.appendingPathComponent("escaped", isDirectory: false)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("zeta", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("alpha", isDirectory: true),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: workspace) }

        let command = ProjectDiscoveryService.remoteDirectoryListingCommand(root: rootName)
        let directories = try await ProjectDiscoveryService.listDirectories(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "cd \"$1\" && \(command)", "holoscape-test", workspace.path],
            timeout: 1
        )

        XCTAssertEqual(directories, ["alpha", "zeta"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testRemoteDirectoryListingCommandPreservesLeadingTildeHomeExpansion() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape remote home \(UUID().uuidString)", isDirectory: true)
        let root = home.appendingPathComponent("projects with spaces", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("holoscape", isDirectory: true),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }

        let command = ProjectDiscoveryService.remoteDirectoryListingCommand(root: "~/projects with spaces")
        let directories = try await ProjectDiscoveryService.listDirectories(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["HOME=\(home.path)", "/bin/sh", "-c", command],
            timeout: 1
        )
        let homeDirectories = try await ProjectDiscoveryService.listDirectories(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [
                "HOME=\(home.path)",
                "/bin/sh",
                "-c",
                ProjectDiscoveryService.remoteDirectoryListingCommand(root: "~"),
            ],
            timeout: 1
        )

        XCTAssertEqual(directories, ["holoscape"])
        XCTAssertEqual(homeDirectories, ["projects with spaces"])
    }

    func testRemoteDirectoryListingDrainsHighVolumeStderr() async throws {
        let script = try makeDiscoveryScript("""
        i=0
        while [ "$i" -lt 20000 ]; do
          printf 'diagnostic-%05d: project discovery warning payload\\n' "$i" >&2
          i=$((i + 1))
        done
        printf 'holoscape\\n'
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        let directories = try await ProjectDiscoveryService.listDirectories(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [script.path],
            timeout: 5
        )

        XCTAssertEqual(directories, ["holoscape"])
    }

    func testRemoteDirectoryListingTimesOutHungProcess() async throws {
        let script = try makeDiscoveryScript("exec sleep 5")
        defer { try? FileManager.default.removeItem(at: script) }

        let startedAt = Date()
        do {
            _ = try await ProjectDiscoveryService.listDirectories(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [script.path],
                timeout: 0.05
            )
            XCTFail("Expected project discovery to time out")
        } catch {
            XCTAssertEqual(error as? ProjectDiscoveryService.DiscoveryError, .processTimedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testRemoteDirectoryListingPreservesReadFailureWhenProcessRemainsAlive() async throws {
        let script = try makeDiscoveryScript("exec sleep 1")
        defer { try? FileManager.default.removeItem(at: script) }

        do {
            _ = try await ProjectDiscoveryService.listDirectories(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [script.path],
                timeout: 0.05,
                readChunk: { _, _ in throw SyntheticReadError.failed }
            )
            XCTFail("Expected the pipe read failure to take precedence over timeout")
        } catch {
            XCTAssertEqual(
                error as? ProjectDiscoveryService.DiscoveryError,
                .outputReadFailed(stream: "stdout", message: "failed")
            )
        }
    }

    func testRemoteDirectoryListingTimesOutWhenExitedParentLeavesPipeOpen() async throws {
        let script = try makeDiscoveryScript("sleep 1 & exit 0")
        defer { try? FileManager.default.removeItem(at: script) }

        let startedAt = Date()
        do {
            _ = try await ProjectDiscoveryService.listDirectories(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [script.path],
                timeout: 0.05
            )
            XCTFail("Expected inherited open pipes to respect the operation timeout")
        } catch {
            XCTAssertEqual(error as? ProjectDiscoveryService.DiscoveryError, .processTimedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.75)
    }

    func testRemoteDirectoryListingReportsOutputLimitWhenExitedParentLeavesPipeOpen() async throws {
        let script = try makeDiscoveryScript("printf 'oversized-output\\n'; sleep 1 & exit 0")
        defer { try? FileManager.default.removeItem(at: script) }

        let startedAt = Date()
        do {
            _ = try await ProjectDiscoveryService.listDirectories(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [script.path],
                timeout: 0.05,
                maxOutputBytes: 8
            )
            XCTFail("Expected output overflow to take precedence over an inherited open pipe")
        } catch {
            XCTAssertEqual(
                error as? ProjectDiscoveryService.DiscoveryError,
                .outputLimitExceeded(stream: "stdout", maxBytes: 8)
            )
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.75)
    }

    func testRemoteDirectoryListingPreservesNonzeroExitAndStderrAfterExitedParentLeavesPipeOpen() async throws {
        let script = try makeDiscoveryScript("printf 'permission denied\\n' >&2; sleep 1 & exit 7")
        defer { try? FileManager.default.removeItem(at: script) }

        let startedAt = Date()
        do {
            _ = try await ProjectDiscoveryService.listDirectories(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [script.path],
                timeout: 0.05
            )
            XCTFail("Expected the exited parent's nonzero status to be preserved")
        } catch {
            XCTAssertEqual(
                error as? ProjectDiscoveryService.DiscoveryError,
                .processFailed(exitCode: 7, stderr: "permission denied")
            )
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.75)
    }

    func testRemoteDirectoryListingPreservesNonzeroExitAndStderr() async throws {
        let script = try makeDiscoveryScript("""
        printf 'permission denied\\n' >&2
        exit 7
        """)
        defer { try? FileManager.default.removeItem(at: script) }

        do {
            _ = try await ProjectDiscoveryService.listDirectories(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [script.path],
                timeout: 1
            )
            XCTFail("Expected project discovery to report the process failure")
        } catch {
            XCTAssertEqual(
                error as? ProjectDiscoveryService.DiscoveryError,
                .processFailed(exitCode: 7, stderr: "permission denied")
            )
        }
    }

    func testRemoteDirectoryListingRejectsStdoutBeyondConfiguredLimit() async throws {
        let script = try makeDiscoveryScript("printf 'project-name-that-exceeds-the-test-limit\\n'")
        defer { try? FileManager.default.removeItem(at: script) }

        do {
            _ = try await ProjectDiscoveryService.listDirectories(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [script.path],
                timeout: 1,
                maxOutputBytes: 8
            )
            XCTFail("Expected oversized stdout to fail explicitly")
        } catch {
            XCTAssertEqual(
                error as? ProjectDiscoveryService.DiscoveryError,
                .outputLimitExceeded(stream: "stdout", maxBytes: 8)
            )
        }
    }

    func testRemoteDirectoryListingRejectsStderrBeyondConfiguredLimit() async throws {
        let script = try makeDiscoveryScript("printf 'diagnostic-that-exceeds-the-test-limit\\n' >&2; exit 7")
        defer { try? FileManager.default.removeItem(at: script) }

        do {
            _ = try await ProjectDiscoveryService.listDirectories(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [script.path],
                timeout: 1,
                maxOutputBytes: 8
            )
            XCTFail("Expected oversized stderr to fail explicitly")
        } catch {
            XCTAssertEqual(
                error as? ProjectDiscoveryService.DiscoveryError,
                .outputLimitExceeded(stream: "stderr", maxBytes: 8)
            )
        }
    }

    @MainActor
    func testRefreshDiscoveredSessionsPopulatesLauncherProjectCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-local-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("holoscape", isDirectory: true), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-local-refresh-config-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: configDir) }
        let configService = ConfigService(configDir: configDir)
        var config = HoloscapeConfig.default
        config.projectDiscovery = ProjectDiscoveryConfig(enabled: true, root: root.path, connection: "local", command: "claude")
        configService.save(config)

        let discoveryService = ProjectDiscoveryService(configService: configService)
        let manager = SessionProfileManager(configService: configService, discoveryService: discoveryService)

        XCTAssertTrue(manager.allSessions().discovered.isEmpty)
        _ = await manager.refreshDiscoveredSessions()

        XCTAssertEqual(manager.allSessions().discovered.map(\.label), ["holoscape"])
    }

    @MainActor
    func testRefreshDiscoveredSessionsPreservesCacheWhenLocalRootBecomesUnreadable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-local-refresh-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("holoscape", isDirectory: true),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-local-refresh-failure-config-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: configDir) }
        let configService = ConfigService(configDir: configDir)
        var config = HoloscapeConfig.default
        config.projectDiscovery = ProjectDiscoveryConfig(enabled: true, root: root.path, connection: "local", command: "claude")
        configService.save(config)

        let discoveryService = ProjectDiscoveryService(configService: configService)
        let manager = SessionProfileManager(configService: configService, discoveryService: discoveryService)
        let initialProjects = await manager.refreshDiscoveredSessions()
        XCTAssertEqual(initialProjects.map(\.label), ["holoscape"])

        try FileManager.default.removeItem(at: root)
        try Data("not a directory".utf8).write(to: root)

        let projectsAfterFailure = await manager.refreshDiscoveredSessions()
        XCTAssertEqual(projectsAfterFailure.map(\.label), ["holoscape"])
        XCTAssertEqual(manager.allSessions().discovered.map(\.label), ["holoscape"])
    }

    @MainActor
    func testRefreshDiscoveredSessionsTreatsReadableEmptyLocalRootAsAuthoritative() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-local-refresh-empty-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("holoscape", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-local-refresh-empty-config-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: configDir) }
        let configService = ConfigService(configDir: configDir)
        var config = HoloscapeConfig.default
        config.projectDiscovery = ProjectDiscoveryConfig(enabled: true, root: root.path, connection: "local", command: "claude")
        configService.save(config)

        let discoveryService = ProjectDiscoveryService(configService: configService)
        let manager = SessionProfileManager(configService: configService, discoveryService: discoveryService)
        let initialProjects = await manager.refreshDiscoveredSessions()
        XCTAssertEqual(initialProjects.map(\.label), ["holoscape"])

        try FileManager.default.removeItem(at: project)

        let projectsAfterEmptyRefresh = await manager.refreshDiscoveredSessions()
        XCTAssertTrue(projectsAfterEmptyRefresh.isEmpty)
        XCTAssertTrue(manager.allSessions().discovered.isEmpty)
    }

    @MainActor
    func testRefreshDiscoveredSessionsClearsCacheWhenDiscoveryIsDisabled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-local-refresh-disabled-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("holoscape", isDirectory: true),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-local-refresh-disabled-config-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: configDir) }
        let configService = ConfigService(configDir: configDir)
        var config = HoloscapeConfig.default
        config.projectDiscovery = ProjectDiscoveryConfig(enabled: true, root: root.path, connection: "local", command: "claude")
        configService.save(config)

        let discoveryService = ProjectDiscoveryService(configService: configService)
        let manager = SessionProfileManager(configService: configService, discoveryService: discoveryService)
        let initialProjects = await manager.refreshDiscoveredSessions()
        XCTAssertEqual(initialProjects.map(\.label), ["holoscape"])

        config.projectDiscovery?.enabled = false
        configService.save(config)

        let projectsAfterDisable = await manager.refreshDiscoveredSessions()
        XCTAssertTrue(projectsAfterDisable.isEmpty)
        XCTAssertTrue(manager.allSessions().discovered.isEmpty)
    }

    @MainActor
    func testRefreshDiscoveredSessionsDoesNotReuseCacheAfterConfigurationChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-local-refresh-source-a-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("holoscape", isDirectory: true),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-local-refresh-source-config-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: configDir) }
        let configService = ConfigService(configDir: configDir)
        var config = HoloscapeConfig.default
        config.projectDiscovery = ProjectDiscoveryConfig(enabled: true, root: root.path, connection: "local", command: "claude")
        configService.save(config)

        let discoveryService = ProjectDiscoveryService(configService: configService)
        let manager = SessionProfileManager(configService: configService, discoveryService: discoveryService)
        let initialProjects = await manager.refreshDiscoveredSessions()
        XCTAssertEqual(initialProjects.map(\.label), ["holoscape"])

        config.projectDiscovery?.root = root.appendingPathComponent("missing-root", isDirectory: true).path
        configService.save(config)

        let projectsAfterSourceChange = await manager.refreshDiscoveredSessions()
        XCTAssertTrue(projectsAfterSourceChange.isEmpty)
        XCTAssertTrue(manager.allSessions().discovered.isEmpty)
    }

    @MainActor
    func testObsoleteSSHRefreshCannotOverwriteNewerSourceCache() async throws {
        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-ssh-refresh-order-config-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: configDir) }
        let configService = ConfigService(configDir: configDir)
        var config = HoloscapeConfig.default
        config.sshDefaults = SSHDefaults(host: "source-a.local", user: "erik")
        config.projectDiscovery = ProjectDiscoveryConfig(
            enabled: true,
            root: "/remote/a",
            connection: "ssh",
            command: "claude"
        )
        configService.save(config)

        let lister = DeferredRemoteDirectoryLister()
        let discoveryService = ProjectDiscoveryService(
            configService: configService,
            remoteDirectoryLister: { _, _, root in
                try await lister.list(root: root)
            }
        )

        let obsoleteRefresh = Task { await discoveryService.refresh() }
        await lister.waitForRequest(root: "/remote/a")

        config.sshDefaults = SSHDefaults(host: "source-b.local", user: "erik")
        config.projectDiscovery?.root = "/remote/b"
        configService.save(config)

        let currentRefresh = Task { await discoveryService.refresh() }
        await lister.waitForRequest(root: "/remote/b")
        await lister.succeed(root: "/remote/b", directories: ["current-project"])
        let currentProjects = await currentRefresh.value

        await lister.succeed(root: "/remote/a", directories: ["obsolete-project"])
        let obsoleteResult = await obsoleteRefresh.value

        XCTAssertEqual(currentProjects.map(\.label), ["current-project"])
        XCTAssertEqual(obsoleteResult.map(\.label), ["current-project"])
        XCTAssertEqual(discoveryService.cached().map(\.label), ["current-project"])
        XCTAssertEqual(discoveryService.cached().map(\.host), ["source-b.local"])
    }

    @MainActor
    func testSSHCompletionRechecksConfigurationWithoutAnotherCacheCall() async throws {
        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-ssh-completion-config-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: configDir) }
        let configService = ConfigService(configDir: configDir)
        var config = HoloscapeConfig.default
        config.sshDefaults = SSHDefaults(host: "source-a.local", user: "erik")
        config.projectDiscovery = ProjectDiscoveryConfig(
            enabled: true,
            root: "/remote/a",
            connection: "ssh",
            command: "claude"
        )
        configService.save(config)

        let lister = DeferredRemoteDirectoryLister()
        let discoveryService = ProjectDiscoveryService(
            configService: configService,
            remoteDirectoryLister: { _, _, root in
                try await lister.list(root: root)
            }
        )
        let obsoleteRefresh = Task { await discoveryService.refresh() }
        await lister.waitForRequest(root: "/remote/a")

        config.projectDiscovery?.enabled = false
        configService.save(config)
        await lister.succeed(root: "/remote/a", directories: ["obsolete-project"])

        let obsoleteProjects = await obsoleteRefresh.value
        XCTAssertTrue(obsoleteProjects.isEmpty)
        XCTAssertTrue(discoveryService.cached().isEmpty)
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
    func testBuiltInProfilesExposeAllNewChannelTypesInLauncher() {
        let labels = SessionProfileManager.builtInProfiles.map(\.label)

        XCTAssertTrue(labels.contains("Shell"))
        XCTAssertTrue(labels.contains("Agent (OAuth)"))
        XCTAssertTrue(labels.contains("Agent (API Key)"))
        XCTAssertTrue(labels.contains("Group Chat"))
        XCTAssertTrue(labels.contains("Bridge"))
    }

    @MainActor
    func testUnifiedLauncherMapsNewChannelItemsToDirectActions() {
        XCTAssertEqual(MainWindowController.unifiedLauncherAction(for: "Shell"), .shell)
        XCTAssertEqual(MainWindowController.unifiedLauncherAction(for: "Agent (OAuth)"), .agentOAuthDraft)
        XCTAssertEqual(MainWindowController.unifiedLauncherAction(for: "Agent (API Key)"), .agentAPIKeyDraft)
        XCTAssertEqual(MainWindowController.unifiedLauncherAction(for: "Group Chat"), .groupChat)
        XCTAssertEqual(MainWindowController.unifiedLauncherAction(for: "Bridge"), .bridge)
        XCTAssertEqual(MainWindowController.unifiedLauncherAction(for: "holoscape"), .sessionProfile("holoscape"))
    }

    @MainActor
    func testUnifiedLauncherMapsInlineAgentFieldsToCreateAction() {
        let action = MainWindowController.unifiedLauncherAction(
            for: "Agent (OAuth) /Users/erik/projects/holoscape as Holoscape Agent"
        )

        XCTAssertEqual(
            action,
            .agentOAuth(.init(
                workingDirectory: URL(fileURLWithPath: "/Users/erik/projects/holoscape"),
                label: "Holoscape Agent"
            ))
        )
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

    private func makeDiscoveryScript(_ body: String) throws -> URL {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-project-discovery-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
        return script
    }

    private enum SyntheticReadError: Error {
        case failed
    }
}

private actor DeferredRemoteDirectoryLister {
    private var continuations: [String: CheckedContinuation<[String], Error>] = [:]

    func list(root: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            continuations[root] = continuation
        }
    }

    func waitForRequest(root: String) async {
        while continuations[root] == nil {
            await Task.yield()
        }
    }

    func succeed(root: String, directories: [String]) {
        continuations.removeValue(forKey: root)?.resume(returning: directories)
    }
}
