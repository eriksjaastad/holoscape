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
    static let defaultEndpoint = "http://localhost:8000"

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

    func prepareStart(
        manifest: ValidatedPluginManifest,
        configuration: ProjectTrackerPluginConfiguration = .default
    ) throws -> ProjectTrackerPluginStartPlan {
        guard configuration.enabled else { return .disabled(pluginID: manifest.id) }
        guard manifest.id == Self.pluginID else {
            throw ProjectTrackerPluginStartError.wrongManifestID(manifest.id)
        }
        guard manifest.capabilities.isSuperset(of: [.channelProvider, .commandProvider, .statusAdapter]) else {
            throw ProjectTrackerPluginStartError.requiredCapabilitiesMissing(manifest.id)
        }

        let endpoint = try configuration.normalizedEndpoint()
        try enforceNetworkPermission(for: endpoint, manifest: manifest)

        return .ready(
            .init(
                pluginID: manifest.id,
                displayName: manifest.displayName,
                endpoint: endpoint,
                storageNamespace: manifest.storageNamespace,
                capabilities: manifest.capabilities
            )
        )
    }

    private func enforceNetworkPermission(
        for endpoint: URL,
        manifest: ValidatedPluginManifest
    ) throws {
        guard let host = endpoint.host(percentEncoded: false)?.lowercased(), !host.isEmpty else {
            throw ProjectTrackerPluginStartError.invalidEndpoint(endpoint.absoluteString)
        }

        if Self.isLocalhost(host) {
            guard manifest.permissions.contains(.networkLocalhost) else {
                throw ProjectTrackerPluginStartError.permissionMissing(
                    manifest.id,
                    endpoint.absoluteString,
                    .networkLocalhost
                )
            }
            return
        }

        let hostPermission = PluginPermission.networkHost(host)
        guard manifest.permissions.contains(hostPermission) else {
            throw ProjectTrackerPluginStartError.permissionMissing(
                manifest.id,
                endpoint.absoluteString,
                hostPermission
            )
        }
    }

    private static func isLocalhost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

struct ProjectTrackerPluginConfiguration: Equatable, Sendable {
    static let `default` = ProjectTrackerPluginConfiguration()

    var enabled: Bool
    var endpoint: String

    init(enabled: Bool = true, endpoint: String = ProjectTrackerPlugin.defaultEndpoint) {
        self.enabled = enabled
        self.endpoint = endpoint
    }

    func normalizedEndpoint() throws -> URL {
        let rawEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: rawEndpoint) else {
            throw ProjectTrackerPluginStartError.invalidEndpoint(endpoint)
        }
        guard let scheme = components.scheme?.lowercased() else {
            throw ProjectTrackerPluginStartError.invalidEndpoint(endpoint)
        }
        guard scheme == "http" || scheme == "https" else {
            throw ProjectTrackerPluginStartError.unsupportedScheme(scheme)
        }
        guard let host = components.host,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectTrackerPluginStartError.invalidEndpoint(endpoint)
        }

        var normalized = components
        normalized.scheme = scheme
        normalized.host = host.lowercased()
        normalized.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !normalized.path.isEmpty {
            normalized.path = "/\(normalized.path)"
        }
        normalized.query = nil
        normalized.fragment = nil

        guard let url = normalized.url else {
            throw ProjectTrackerPluginStartError.invalidEndpoint(endpoint)
        }
        return url
    }
}

enum ProjectTrackerPluginStartPlan: Equatable, Sendable {
    case disabled(pluginID: String)
    case ready(ProjectTrackerPluginRuntimePlan)
}

struct ProjectTrackerPluginRuntimePlan: Equatable, Sendable {
    let pluginID: String
    let displayName: String
    let endpoint: URL
    let storageNamespace: String
    let capabilities: Set<PluginCapability>
}

enum ProjectTrackerPluginStartError: Error, Equatable, CustomStringConvertible {
    case wrongManifestID(String)
    case requiredCapabilitiesMissing(String)
    case invalidEndpoint(String)
    case unsupportedScheme(String)
    case permissionMissing(String, String, PluginPermission)

    var description: String {
        switch self {
        case .wrongManifestID(let id):
            return "Project Tracker plugin cannot start from manifest \(id)"
        case .requiredCapabilitiesMissing(let id):
            return "Project Tracker plugin \(id) is missing required contribution capabilities"
        case .invalidEndpoint(let endpoint):
            return "Project Tracker plugin endpoint is invalid: \(endpoint)"
        case .unsupportedScheme(let scheme):
            return "Project Tracker plugin endpoint scheme is unsupported: \(scheme)"
        case .permissionMissing(let id, let endpoint, let permission):
            return "Project Tracker plugin \(id) endpoint \(endpoint) requires undeclared permission \(permission.rawValue)"
        }
    }
}
