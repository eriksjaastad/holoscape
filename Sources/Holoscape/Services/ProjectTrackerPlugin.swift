import Foundation

struct PluginRegistry: Sendable {
    private let bundledManifests: [PluginManifest]
    private let validator: PluginManifestValidator

    init(
        bundledManifests: [PluginManifest] = [ProjectTrackerPlugin.manifest],
        validator: PluginManifestValidator = PluginManifestValidator()
    ) {
        self.bundledManifests = bundledManifests
        self.validator = validator
    }

    func bundledPlugins() throws -> [ValidatedPluginManifest] {
        try bundledManifests.map { manifest in
            try validator.validate(manifest)
        }
    }
}

struct ProjectTrackerPlugin: Sendable {
    static let pluginID = "com.holoscape.project-tracker"

    static let manifest = PluginManifest(
        id: pluginID,
        displayName: "Project Tracker",
        version: "0.1.0",
        minimumHoloscapeVersion: "0.1.0",
        capabilities: [
            .channelProvider,
            .commandProvider,
            .statusAdapter,
        ],
        permissions: [
            .networkLocalhost,
            .filesystemPluginStorage,
        ],
        storageNamespace: "project-tracker",
        entrypoint: PluginEntrypoint(
            kind: .bundledSwift,
            bundleIdentifier: nil
        )
    )
}
