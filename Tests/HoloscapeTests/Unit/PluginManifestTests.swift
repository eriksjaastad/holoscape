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
