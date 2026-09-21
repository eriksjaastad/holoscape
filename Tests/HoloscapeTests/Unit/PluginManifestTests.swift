import XCTest
@testable import Holoscape

final class PluginManifestTests: XCTestCase {
    func testBundledProjectTrackerPluginManifestIsValidAndRemovable() throws {
        let plugins = try PluginRegistry().bundledPlugins()
        let projectTracker = try XCTUnwrap(plugins.first { $0.id == ProjectTrackerPlugin.pluginID })

        XCTAssertEqual(projectTracker.displayName, "Project Tracker")
        XCTAssertEqual(projectTracker.storageNamespace, "project-tracker")
        XCTAssertEqual(
            projectTracker.capabilities,
            [.channelProvider, .commandProvider, .statusAdapter]
        )
        XCTAssertEqual(
            projectTracker.permissions,
            [.networkLocalhost, .filesystemPluginStorage]
        )
        XCTAssertEqual(projectTracker.manifest.entrypoint.kind, .bundledSwift)
        XCTAssertNil(projectTracker.manifest.entrypoint.bundleIdentifier)
    }

    func testCoreCanStartWithZeroBundledPlugins() throws {
        let registry = PluginRegistry(bundledManifests: [])

        XCTAssertEqual(try registry.bundledPlugins(), [])
    }

    func testUnknownCapabilityIsRejectedWhileDecodingManifestBeforeStart() {
        let json = manifestJSON(capabilities: ["channel-provider", "kanban-root"], permissions: ["network:localhost"])

        XCTAssertThrowsError(try decodeManifest(json)) { error in
            XCTAssertTrue(String(describing: error).contains("kanban-root"))
        }
    }

    func testUnknownPermissionIsRejectedWhileDecodingManifestBeforeStart() {
        let json = manifestJSON(capabilities: ["channel-provider"], permissions: ["network:internet"])

        XCTAssertThrowsError(try decodeManifest(json)) { error in
            XCTAssertTrue(String(describing: error).contains("network:internet"))
        }
    }

    func testStorageNamespaceCannotCollideWithCoreStores() {
        let manifest = makeManifest(storageNamespace: "sessions")

        XCTAssertThrowsError(try PluginManifestValidator().validate(manifest)) { error in
            XCTAssertEqual(
                error as? PluginManifestValidationError,
                .coreStorageNamespaceCollision("com.example.plugin", "sessions")
            )
        }
    }

    func testStorageProviderRequiresPluginStoragePermission() {
        let manifest = makeManifest(
            capabilities: [.storageProvider],
            permissions: []
        )

        XCTAssertThrowsError(try PluginManifestValidator().validate(manifest)) { error in
            XCTAssertEqual(
                error as? PluginManifestValidationError,
                .storagePermissionMissing("com.example.plugin")
            )
        }
    }

    func testNotificationProviderRequiresPluginNotificationPermission() {
        let manifest = makeManifest(
            capabilities: [.notificationProvider],
            permissions: []
        )

        XCTAssertThrowsError(try PluginManifestValidator().validate(manifest)) { error in
            XCTAssertEqual(
                error as? PluginManifestValidationError,
                .notificationPermissionMissing("com.example.plugin")
            )
        }
    }

    func testInvalidStorageNamespaceIsRejected() {
        let manifest = makeManifest(storageNamespace: "../sessions")

        XCTAssertThrowsError(try PluginManifestValidator().validate(manifest)) { error in
            XCTAssertEqual(
                error as? PluginManifestValidationError,
                .invalidStorageNamespace("com.example.plugin", "../sessions")
            )
        }
    }

    func testProjectTrackerPluginCanPrepareDefaultLocalhostStartPlan() throws {
        let manifest = try PluginManifestValidator().validate(ProjectTrackerPlugin.manifest)

        let plan = try ProjectTrackerPlugin().prepareStart(manifest: manifest)

        XCTAssertEqual(
            plan,
            .ready(
                ProjectTrackerPluginRuntimePlan(
                    pluginID: ProjectTrackerPlugin.pluginID,
                    displayName: "Project Tracker",
                    endpoint: try XCTUnwrap(URL(string: "http://localhost:8000")),
                    healthURL: try XCTUnwrap(URL(string: "http://localhost:8000/health")),
                    storageNamespace: "project-tracker",
                    capabilities: [.channelProvider, .commandProvider, .statusAdapter]
                )
            )
        )
    }

    func testDisabledProjectTrackerPluginDoesNotPrepareEndpointOrFallback() throws {
        let manifest = try PluginManifestValidator().validate(ProjectTrackerPlugin.manifest)
        let configuration = ProjectTrackerPluginConfiguration(
            enabled: false,
            endpoint: "not a url"
        )

        let plan = try ProjectTrackerPlugin().prepareStart(manifest: manifest, configuration: configuration)

        XCTAssertEqual(plan, .disabled(pluginID: ProjectTrackerPlugin.pluginID))
    }

    func testProjectTrackerPluginRejectsRemoteEndpointWithoutDeclaredHostPermission() throws {
        let manifest = try PluginManifestValidator().validate(ProjectTrackerPlugin.manifest)
        let configuration = ProjectTrackerPluginConfiguration(endpoint: "http://macbook-pro:8000")

        XCTAssertThrowsError(try ProjectTrackerPlugin().prepareStart(manifest: manifest, configuration: configuration)) { error in
            XCTAssertEqual(
                error as? ProjectTrackerPluginStartError,
                .permissionMissing(
                    ProjectTrackerPlugin.pluginID,
                    "http://macbook-pro:8000",
                    .networkHost("macbook-pro")
                )
            )
        }
    }

    func testProjectTrackerPluginAllowsRemoteEndpointOnlyWithDeclaredHostPermission() throws {
        let manifest = ProjectTrackerPlugin.manifest.withPermissions([
            .networkLocalhost,
            .networkHost("macbook-pro"),
            .filesystemPluginStorage,
        ])
        let validated = try PluginManifestValidator().validate(manifest)
        let configuration = ProjectTrackerPluginConfiguration(endpoint: "http://macbook-pro:8000")

        let plan = try ProjectTrackerPlugin().prepareStart(manifest: validated, configuration: configuration)

        guard case .ready(let runtimePlan) = plan else {
            return XCTFail("Expected ready Project Tracker start plan")
        }
        XCTAssertEqual(runtimePlan.endpoint, URL(string: "http://macbook-pro:8000"))
    }

    func testProjectTrackerPluginRejectsInvalidEndpointInsteadOfFallingBackToLocalhost() throws {
        let manifest = try PluginManifestValidator().validate(ProjectTrackerPlugin.manifest)
        let configuration = ProjectTrackerPluginConfiguration(endpoint: "project-tracker.local")

        XCTAssertThrowsError(try ProjectTrackerPlugin().prepareStart(manifest: manifest, configuration: configuration)) { error in
            XCTAssertEqual(
                error as? ProjectTrackerPluginStartError,
                .invalidEndpoint("project-tracker.local")
            )
        }
    }

    func testProjectTrackerPluginRejectsUnsupportedEndpointScheme() throws {
        let manifest = try PluginManifestValidator().validate(ProjectTrackerPlugin.manifest)
        let configuration = ProjectTrackerPluginConfiguration(endpoint: "file:///tmp/project-tracker.sock")

        XCTAssertThrowsError(try ProjectTrackerPlugin().prepareStart(manifest: manifest, configuration: configuration)) { error in
            XCTAssertEqual(
                error as? ProjectTrackerPluginStartError,
                .unsupportedScheme("file")
            )
        }
    }

    func testProjectTrackerPluginRejectsInvalidHealthPathBeforeRuntimeStart() throws {
        let manifest = try PluginManifestValidator().validate(ProjectTrackerPlugin.manifest)
        let configuration = ProjectTrackerPluginConfiguration(healthPath: "../health")

        XCTAssertThrowsError(try ProjectTrackerPlugin().prepareStart(manifest: manifest, configuration: configuration)) { error in
            XCTAssertEqual(
                error as? ProjectTrackerPluginStartError,
                .invalidHealthPath("../health")
            )
        }
    }

    func testProjectTrackerRuntimeBuildsExplicitBoardURLsWithoutCoreStateCoupling() throws {
        let plan = try projectTrackerRuntimePlan()

        XCTAssertEqual(
            try plan.projectBoardURL(projectSlug: "holoscape"),
            URL(string: "http://localhost:8000/kanban/holoscape")
        )
        XCTAssertThrowsError(try plan.projectBoardURL(projectSlug: "../holoscape")) { error in
            XCTAssertEqual(error as? ProjectTrackerPluginRuntimeError, .invalidProjectSlug("../holoscape"))
        }
    }

    func testProjectTrackerCommandActionOpensOnlyExplicitBoardURL() throws {
        let plan = try projectTrackerRuntimePlan()

        XCTAssertEqual(
            try plan.commandAction(
                descriptorID: ProjectTrackerPlugin.openBoardCommandID,
                arguments: ["projectSlug": "holoscape"]
            ),
            .openExternalURL(try XCTUnwrap(URL(string: "http://localhost:8000/kanban/holoscape")))
        )
        XCTAssertThrowsError(
            try plan.commandAction(
                descriptorID: ProjectTrackerPlugin.openBoardCommandID,
                arguments: [:]
            )
        ) { error in
            XCTAssertEqual(error as? ProjectTrackerPluginRuntimeError, .missingCommandArgument("projectSlug"))
        }
    }

    func testProjectTrackerCommandRejectsUnknownDescriptorWithoutFallback() throws {
        let plan = try projectTrackerRuntimePlan()

        XCTAssertThrowsError(
            try plan.commandAction(
                descriptorID: "project-tracker-sync-all",
                arguments: ["projectSlug": "holoscape"]
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectTrackerPluginRuntimeError,
                .unknownCommand("project-tracker-sync-all")
            )
        }
    }

    func testProjectTrackerContributionDescriptorDeclaresRequiredCommandArgument() {
        let snapshot = PluginManager().prepareStartup()

        XCTAssertEqual(snapshot.contributions.commandDescriptors, [
            .init(
                pluginID: ProjectTrackerPlugin.pluginID,
                id: ProjectTrackerPlugin.openBoardCommandID,
                displayName: "Open Project Tracker Board",
                requiredArguments: ["projectSlug"]
            ),
        ])
    }

    func testPluginCommandRouterOpensProjectTrackerBoardThroughInjectedURLOpener() throws {
        let opener = RecordingPluginExternalURLOpener()
        let router = PluginCommandRouter(
            startupSnapshot: PluginManager().prepareStartup(),
            externalURLOpener: opener
        )

        let result = try router.execute(
            descriptorID: ProjectTrackerPlugin.openBoardCommandID,
            arguments: ["projectSlug": "holoscape"]
        )

        let expectedURL = try XCTUnwrap(URL(string: "http://localhost:8000/kanban/holoscape"))
        XCTAssertEqual(result, .openedExternalURL(expectedURL))
        XCTAssertEqual(opener.openedURLs, [expectedURL])
    }

    func testPluginCommandRouterRefusesDisabledPluginCommandsWithoutFallback() throws {
        let opener = RecordingPluginExternalURLOpener()
        let router = PluginCommandRouter(
            startupSnapshot: PluginManager(projectTrackerConfiguration: .init(enabled: false)).prepareStartup(),
            externalURLOpener: opener
        )

        XCTAssertThrowsError(
            try router.execute(
                descriptorID: ProjectTrackerPlugin.openBoardCommandID,
                arguments: ["projectSlug": "holoscape"]
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginCommandExecutionError,
                .commandNotAdvertised(ProjectTrackerPlugin.openBoardCommandID)
            )
        }
        XCTAssertEqual(opener.openedURLs, [])
    }

    func testPluginCommandRouterRejectsUnadvertisedCommandsBeforePluginRuntimeResolution() throws {
        let opener = RecordingPluginExternalURLOpener()
        let router = PluginCommandRouter(
            startupSnapshot: PluginManager().prepareStartup(),
            externalURLOpener: opener
        )

        XCTAssertThrowsError(
            try router.execute(
                descriptorID: "project-tracker-sync-all",
                arguments: ["projectSlug": "holoscape"]
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginCommandExecutionError,
                .commandNotAdvertised("project-tracker-sync-all")
            )
        }
        XCTAssertEqual(opener.openedURLs, [])
    }

    func testProjectTrackerRuntimeHealthUsesConfiguredHealthURL() async throws {
        let plan = try projectTrackerRuntimePlan()
        let transport = RecordingProjectTrackerTransport(result: .success(.init(statusCode: 204, body: Data())))
        let runtime = ProjectTrackerPluginRuntime(plan: plan, transport: transport)

        let health = await runtime.health()

        XCTAssertEqual(
            health,
            .available(
                .init(
                    pluginID: ProjectTrackerPlugin.pluginID,
                    endpoint: try XCTUnwrap(URL(string: "http://localhost:8000")),
                    healthURL: try XCTUnwrap(URL(string: "http://localhost:8000/health"))
                )
            )
        )
        let requestedURLs = await transport.requestedURLs
        XCTAssertEqual(requestedURLs, [try XCTUnwrap(URL(string: "http://localhost:8000/health"))])
    }

    func testProjectTrackerRuntimeHealthFailureStaysPluginScoped() async throws {
        let plan = try projectTrackerRuntimePlan()
        let transport = RecordingProjectTrackerTransport(result: .success(.init(statusCode: 503, body: Data())))
        let runtime = ProjectTrackerPluginRuntime(plan: plan, transport: transport)

        let health = await runtime.health()

        XCTAssertEqual(
            health,
            .unavailable(
                .init(
                    pluginID: ProjectTrackerPlugin.pluginID,
                    endpoint: try XCTUnwrap(URL(string: "http://localhost:8000")),
                    healthURL: try XCTUnwrap(URL(string: "http://localhost:8000/health")),
                    reason: .httpStatus(503)
                )
            )
        )
    }

    func testProjectTrackerStatusAdapterProducesSupplementalStatusOnly() async throws {
        let plan = try projectTrackerRuntimePlan()
        let transport = RecordingProjectTrackerTransport(result: .success(.init(statusCode: 503, body: Data())))
        let runtime = ProjectTrackerPluginRuntime(plan: plan, transport: transport)

        let status = await runtime.statusAdapterSnapshot()

        XCTAssertEqual(
            status,
            PluginSupplementalStatus(
                pluginID: ProjectTrackerPlugin.pluginID,
                adapterID: ProjectTrackerPlugin.taskStatusAdapterID,
                label: "Project Tracker unavailable",
                detail: "HTTP 503 from http://localhost:8000/health",
                severity: .warning
            )
        )
    }

    func testPluginManagerCanStartCoreWithNoPlugins() {
        let manager = PluginManager(registry: PluginRegistry(bundledManifests: []))

        let snapshot = manager.prepareStartup()

        XCTAssertEqual(snapshot.states, [])
        XCTAssertEqual(snapshot.contributions, .empty)
        XCTAssertEqual(snapshot.failures, [])
    }

    func testPluginManagerDisablingProjectTrackerRemovesAllContributions() {
        let manager = PluginManager(
            projectTrackerConfiguration: .init(enabled: false, endpoint: "not a url")
        )

        let snapshot = manager.prepareStartup()

        XCTAssertEqual(snapshot.states.count, 1)
        guard case .disabled(let disabled) = snapshot.states[0] else {
            return XCTFail("Expected disabled Project Tracker plugin")
        }
        XCTAssertEqual(disabled.pluginID, ProjectTrackerPlugin.pluginID)
        XCTAssertEqual(disabled.removedContributions, .empty)
        XCTAssertEqual(snapshot.contributions, .empty)
        XCTAssertEqual(snapshot.failures, [])
    }

    func testPluginManagerKeepsProjectTrackerConfigurationFailurePluginScoped() {
        let manager = PluginManager(
            projectTrackerConfiguration: .init(endpoint: "project-tracker.local")
        )

        let snapshot = manager.prepareStartup()

        XCTAssertEqual(snapshot.contributions, .empty)
        XCTAssertEqual(snapshot.failures.count, 1)
        XCTAssertEqual(snapshot.failures[0].pluginID, ProjectTrackerPlugin.pluginID)
        XCTAssertTrue(snapshot.failures[0].message.contains("endpoint is invalid"))
    }

    func testPluginManagerPublishesProjectTrackerContributionsOnlyWhenReady() throws {
        let manager = PluginManager()

        let snapshot = manager.prepareStartup()

        XCTAssertEqual(snapshot.failures, [])
        XCTAssertEqual(snapshot.contributions.launcherProfiles, [
            .init(
                pluginID: ProjectTrackerPlugin.pluginID,
                id: "project-tracker-message-board",
                displayName: "Project Tracker Message Board"
            ),
        ])
        XCTAssertEqual(snapshot.contributions.commandDescriptors, [
            .init(
                pluginID: ProjectTrackerPlugin.pluginID,
                id: ProjectTrackerPlugin.openBoardCommandID,
                displayName: "Open Project Tracker Board",
                requiredArguments: ["projectSlug"]
            ),
        ])
        XCTAssertEqual(snapshot.contributions.statusAdapters, [
            .init(
                pluginID: ProjectTrackerPlugin.pluginID,
                id: "project-tracker-task-status",
                displayName: "Project Tracker Task Status"
            ),
        ])
    }

    func testPluginManagerReadsOptionalProjectTrackerConfigFromHoloscapeConfig() throws {
        var config = HoloscapeConfig.default
        config.plugins = .init(
            projectTracker: .init(
                enabled: false,
                endpoint: "not a url",
                healthPath: "../health"
            )
        )

        let manager = PluginManager(config: config)
        let snapshot = manager.prepareStartup()

        XCTAssertEqual(snapshot.states.count, 1)
        guard case .disabled(let disabled) = snapshot.states[0] else {
            return XCTFail("Expected config-disabled Project Tracker plugin")
        }
        XCTAssertEqual(disabled.pluginID, ProjectTrackerPlugin.pluginID)
        XCTAssertEqual(disabled.removedContributions, .empty)
        XCTAssertEqual(snapshot.contributions, .empty)
        XCTAssertEqual(snapshot.failures, [])
    }

    func testProjectTrackerPluginConfigIsOptionalForBackwardCompatibility() throws {
        let json = """
        {
          "appearance": {
            "backgroundColor": "#1a1a2e",
            "transparency": 1.0,
            "fontFamily": "SF Mono",
            "fontSize": 13.0
          },
          "channels": [],
          "lastLaunchTimestamp": null
        }
        """

        let config = try JSONDecoder().decode(HoloscapeConfig.self, from: Data(json.utf8))

        XCTAssertNil(config.plugins)
        XCTAssertEqual(
            config.projectTrackerPluginConfiguration(),
            ProjectTrackerPluginConfiguration.default
        )
    }

    private func decodeManifest(_ json: String) throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
    }

    private func manifestJSON(capabilities: [String], permissions: [String]) -> String {
        let capabilityJSON = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        let permissionJSON = permissions.map { "\"\($0)\"" }.joined(separator: ",")
        return """
        {
          "id": "com.example.plugin",
          "displayName": "Example Plugin",
          "version": "1.0.0",
          "minimumHoloscapeVersion": "0.1.0",
          "capabilities": [\(capabilityJSON)],
          "permissions": [\(permissionJSON)],
          "storageNamespace": "example-plugin",
          "entrypoint": {
            "kind": "bundled-swift",
            "bundleIdentifier": null
          }
        }
        """
    }

    private func makeManifest(
        capabilities: [PluginCapability] = [.channelProvider],
        permissions: [PluginPermission] = [.networkLocalhost],
        storageNamespace: String = "example-plugin"
    ) -> PluginManifest {
        PluginManifest(
            id: "com.example.plugin",
            displayName: "Example Plugin",
            version: "1.0.0",
            minimumHoloscapeVersion: "0.1.0",
            capabilities: capabilities,
            permissions: permissions,
            storageNamespace: storageNamespace,
            entrypoint: PluginEntrypoint(kind: .bundledSwift, bundleIdentifier: nil)
        )
    }

    private func projectTrackerRuntimePlan() throws -> ProjectTrackerPluginRuntimePlan {
        let manifest = try PluginManifestValidator().validate(ProjectTrackerPlugin.manifest)
        let plan = try ProjectTrackerPlugin().prepareStart(manifest: manifest)
        guard case .ready(let runtimePlan) = plan else {
            throw XCTSkip("Expected ready Project Tracker plugin plan")
        }
        return runtimePlan
    }
}

private actor RecordingProjectTrackerTransport: ProjectTrackerPluginHTTPTransport {
    private let result: Result<ProjectTrackerPluginHTTPResponse, Error>
    private var urls: [URL] = []

    init(result: Result<ProjectTrackerPluginHTTPResponse, Error>) {
        self.result = result
    }

    var requestedURLs: [URL] { urls }

    func get(_ url: URL) async throws -> ProjectTrackerPluginHTTPResponse {
        urls.append(url)
        return try result.get()
    }
}

private final class RecordingPluginExternalURLOpener: PluginExternalURLOpening, @unchecked Sendable {
    private(set) var openedURLs: [URL] = []

    func openExternalURL(_ url: URL) {
        openedURLs.append(url)
    }
}

private extension PluginManifest {
    func withPermissions(_ permissions: [PluginPermission]) -> PluginManifest {
        PluginManifest(
            id: id,
            displayName: displayName,
            version: version,
            minimumHoloscapeVersion: minimumHoloscapeVersion,
            capabilities: capabilities,
            permissions: permissions,
            storageNamespace: storageNamespace,
            entrypoint: entrypoint
        )
    }
}
