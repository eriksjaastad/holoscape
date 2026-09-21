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
