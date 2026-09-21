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
    static let openBoardCommandID = "project-tracker-open-board"
    static let taskStatusAdapterID = "project-tracker-task-status"

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
        let healthURL = try configuration.normalizedHealthURL(endpoint: endpoint)
        try enforceNetworkPermission(for: endpoint, manifest: manifest)
        try enforceNetworkPermission(for: healthURL, manifest: manifest)

        return .ready(
            .init(
                pluginID: manifest.id,
                displayName: manifest.displayName,
                endpoint: endpoint,
                healthURL: healthURL,
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
    var healthPath: String

    init(
        enabled: Bool = true,
        endpoint: String = ProjectTrackerPlugin.defaultEndpoint,
        healthPath: String = "/health"
    ) {
        self.enabled = enabled
        self.endpoint = endpoint
        self.healthPath = healthPath
    }

    func normalizedEndpoint() throws -> URL {
        try normalizeEndpoint(endpoint)
    }

    func normalizedHealthURL(endpoint normalizedEndpoint: URL) throws -> URL {
        let path = healthPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.contains("..") else {
            throw ProjectTrackerPluginStartError.invalidHealthPath(healthPath)
        }
        guard let url = normalizedEndpoint.appendingPathComponents(path) else {
            throw ProjectTrackerPluginStartError.invalidHealthPath(healthPath)
        }
        return url
    }

    private func normalizeEndpoint(_ rawValue: String) throws -> URL {
        let rawEndpoint = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: rawEndpoint) else {
            throw ProjectTrackerPluginStartError.invalidEndpoint(rawValue)
        }
        guard let scheme = components.scheme?.lowercased() else {
            throw ProjectTrackerPluginStartError.invalidEndpoint(rawValue)
        }
        guard scheme == "http" || scheme == "https" else {
            throw ProjectTrackerPluginStartError.unsupportedScheme(scheme)
        }
        guard let host = components.host,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectTrackerPluginStartError.invalidEndpoint(rawValue)
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
            throw ProjectTrackerPluginStartError.invalidEndpoint(rawValue)
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
    let healthURL: URL
    let storageNamespace: String
    let capabilities: Set<PluginCapability>

    func projectBoardURL(projectSlug: String) throws -> URL {
        let slug = projectSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty,
              slug.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$"#, options: .regularExpression) != nil else {
            throw ProjectTrackerPluginRuntimeError.invalidProjectSlug(projectSlug)
        }
        guard let url = endpoint.appendingPathComponents("/kanban/\(slug)") else {
            throw ProjectTrackerPluginRuntimeError.invalidProjectSlug(projectSlug)
        }
        return url
    }

    func commandAction(
        descriptorID: String,
        arguments: [String: String]
    ) throws -> PluginCommandAction {
        guard descriptorID == ProjectTrackerPlugin.openBoardCommandID else {
            throw ProjectTrackerPluginRuntimeError.unknownCommand(descriptorID)
        }
        guard let projectSlug = arguments["projectSlug"] else {
            throw ProjectTrackerPluginRuntimeError.missingCommandArgument("projectSlug")
        }
        return .openExternalURL(try projectBoardURL(projectSlug: projectSlug))
    }
}

enum PluginCommandAction: Equatable, Sendable {
    case openExternalURL(URL)
}

enum ProjectTrackerPluginStartError: Error, Equatable, CustomStringConvertible {
    case wrongManifestID(String)
    case requiredCapabilitiesMissing(String)
    case invalidEndpoint(String)
    case unsupportedScheme(String)
    case invalidHealthPath(String)
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
        case .invalidHealthPath(let path):
            return "Project Tracker plugin health path is invalid: \(path)"
        case .permissionMissing(let id, let endpoint, let permission):
            return "Project Tracker plugin \(id) endpoint \(endpoint) requires undeclared permission \(permission.rawValue)"
        }
    }
}

struct ProjectTrackerPluginRuntime: Sendable {
    private let plan: ProjectTrackerPluginRuntimePlan
    private let transport: ProjectTrackerPluginHTTPTransport

    init(
        plan: ProjectTrackerPluginRuntimePlan,
        transport: ProjectTrackerPluginHTTPTransport = URLSessionProjectTrackerPluginHTTPTransport()
    ) {
        self.plan = plan
        self.transport = transport
    }

    func health() async -> ProjectTrackerPluginHealth {
        do {
            let response = try await transport.get(plan.healthURL)
            guard (200..<300).contains(response.statusCode) else {
                return .unavailable(
                    .init(
                        pluginID: plan.pluginID,
                        endpoint: plan.endpoint,
                        healthURL: plan.healthURL,
                        reason: .httpStatus(response.statusCode)
                    )
                )
            }
            return .available(
                .init(
                    pluginID: plan.pluginID,
                    endpoint: plan.endpoint,
                    healthURL: plan.healthURL
                )
            )
        } catch {
            return .unavailable(
                .init(
                    pluginID: plan.pluginID,
                    endpoint: plan.endpoint,
                    healthURL: plan.healthURL,
                    reason: .transport(String(describing: error))
                )
            )
        }
    }

    func statusAdapterSnapshot() async -> PluginSupplementalStatus {
        switch await health() {
        case .available(let available):
            return PluginSupplementalStatus(
                pluginID: available.pluginID,
                adapterID: ProjectTrackerPlugin.taskStatusAdapterID,
                label: "Project Tracker available",
                detail: "Healthy at \(available.healthURL.absoluteString)",
                severity: .info
            )
        case .unavailable(let unavailable):
            return PluginSupplementalStatus(
                pluginID: unavailable.pluginID,
                adapterID: ProjectTrackerPlugin.taskStatusAdapterID,
                label: "Project Tracker unavailable",
                detail: unavailable.reason.statusDetail(healthURL: unavailable.healthURL),
                severity: .warning
            )
        }
    }
}

struct PluginSupplementalStatus: Equatable, Sendable {
    let pluginID: String
    let adapterID: String
    let label: String
    let detail: String
    let severity: PluginSupplementalStatusSeverity
}

enum PluginSupplementalStatusSeverity: String, Equatable, Sendable {
    case info
    case warning
    case error
}

enum ProjectTrackerPluginHealth: Equatable, Sendable {
    case available(ProjectTrackerPluginAvailableHealth)
    case unavailable(ProjectTrackerPluginUnavailableHealth)
}

struct ProjectTrackerPluginAvailableHealth: Equatable, Sendable {
    let pluginID: String
    let endpoint: URL
    let healthURL: URL
}

struct ProjectTrackerPluginUnavailableHealth: Equatable, Sendable {
    let pluginID: String
    let endpoint: URL
    let healthURL: URL
    let reason: ProjectTrackerPluginUnavailableReason
}

enum ProjectTrackerPluginUnavailableReason: Equatable, Sendable {
    case httpStatus(Int)
    case transport(String)

    func statusDetail(healthURL: URL) -> String {
        switch self {
        case .httpStatus(let statusCode):
            return "HTTP \(statusCode) from \(healthURL.absoluteString)"
        case .transport(let message):
            return "Transport failure from \(healthURL.absoluteString): \(message)"
        }
    }
}

enum ProjectTrackerPluginRuntimeError: Error, Equatable, CustomStringConvertible {
    case invalidProjectSlug(String)
    case missingCommandArgument(String)
    case unknownCommand(String)

    var description: String {
        switch self {
        case .invalidProjectSlug(let slug):
            return "Project Tracker project slug is invalid: \(slug)"
        case .missingCommandArgument(let argument):
            return "Project Tracker plugin command is missing required argument: \(argument)"
        case .unknownCommand(let commandID):
            return "Project Tracker plugin command is unknown: \(commandID)"
        }
    }
}

protocol ProjectTrackerPluginHTTPTransport: Sendable {
    func get(_ url: URL) async throws -> ProjectTrackerPluginHTTPResponse
}

struct ProjectTrackerPluginHTTPResponse: Equatable, Sendable {
    let statusCode: Int
    let body: Data
}

final class URLSessionProjectTrackerPluginHTTPTransport: ProjectTrackerPluginHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func get(_ url: URL) async throws -> ProjectTrackerPluginHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProjectTrackerPluginTransportError.nonHTTPResponse
        }
        return ProjectTrackerPluginHTTPResponse(statusCode: httpResponse.statusCode, body: data)
    }
}

enum ProjectTrackerPluginTransportError: Error, Equatable {
    case nonHTTPResponse
}

private extension URL {
    func appendingPathComponents(_ rawPath: String) -> URL? {
        let components = rawPath.split(separator: "/").map(String.init)
        var url = self
        for component in components where !component.isEmpty {
            url.appendPathComponent(component)
        }
        return url
    }
}
