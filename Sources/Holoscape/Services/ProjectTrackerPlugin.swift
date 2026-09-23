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
    static let openTaskCommandID = "project-tracker-open-task"
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
                capabilities: manifest.capabilities,
                permissions: manifest.permissions
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
    let permissions: Set<PluginPermission>

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

    func projectTaskURL(projectSlug: String, taskID: String) throws -> URL {
        let boardURL = try projectBoardURL(projectSlug: projectSlug)
        let id = try normalizedTaskID(taskID)
        guard var components = URLComponents(url: boardURL, resolvingAgainstBaseURL: false) else {
            throw ProjectTrackerPluginRuntimeError.invalidTaskID(taskID)
        }
        components.queryItems = [URLQueryItem(name: "task", value: id)]
        guard let url = components.url else { throw ProjectTrackerPluginRuntimeError.invalidTaskID(taskID) }
        return url
    }

    func taskListAPIURL(projectSlug: String, taskID: String) throws -> URL {
        let slug = try normalizedProjectSlug(projectSlug)
        let id = try normalizedTaskID(taskID)
        guard let listURL = endpoint.appendingPathComponents("/api/tasks"),
              var components = URLComponents(url: listURL, resolvingAgainstBaseURL: false) else {
            throw ProjectTrackerPluginRuntimeError.invalidTaskID(taskID)
        }
        components.queryItems = [
            URLQueryItem(name: "project_id", value: slug),
            URLQueryItem(name: "include_archived", value: "true"),
        ]
        guard let url = components.url else { throw ProjectTrackerPluginRuntimeError.invalidTaskID(id) }
        return url
    }

    private func normalizedProjectSlug(_ projectSlug: String) throws -> String {
        let slug = projectSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !slug.isEmpty,
              slug.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$"#, options: .regularExpression) != nil else {
            throw ProjectTrackerPluginRuntimeError.invalidProjectSlug(projectSlug)
        }
        return slug
    }

    fileprivate func normalizedTaskID(_ taskID: String) throws -> String {
        let id = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty,
              id.range(of: #"^[0-9]{1,18}$"#, options: .regularExpression) != nil else {
            throw ProjectTrackerPluginRuntimeError.invalidTaskID(taskID)
        }
        return id
    }

    func commandAction(
        descriptorID: String,
        arguments: [String: String]
    ) throws -> PluginCommandAction {
        switch descriptorID {
        case ProjectTrackerPlugin.openBoardCommandID:
            guard let projectSlug = arguments["projectSlug"] else {
                throw ProjectTrackerPluginRuntimeError.missingCommandArgument("projectSlug")
            }
            return .openExternalURL(try projectBoardURL(projectSlug: projectSlug))
        case ProjectTrackerPlugin.openTaskCommandID:
            guard let projectSlug = arguments["projectSlug"] else {
                throw ProjectTrackerPluginRuntimeError.missingCommandArgument("projectSlug")
            }
            guard let taskID = arguments["taskID"] else {
                throw ProjectTrackerPluginRuntimeError.missingCommandArgument("taskID")
            }
            return .openExternalURL(try projectTaskURL(projectSlug: projectSlug, taskID: taskID))
        default:
            throw ProjectTrackerPluginRuntimeError.unknownCommand(descriptorID)
        }
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

    func taskStatus(projectSlug: String, taskID: String) async -> ProjectTrackerPluginTaskStatusResult {
        let taskURL: URL
        let normalizedTaskID: String
        do {
            normalizedTaskID = try plan.normalizedTaskID(taskID)
            taskURL = try plan.taskListAPIURL(projectSlug: projectSlug, taskID: taskID)
        } catch let error as ProjectTrackerPluginRuntimeError {
            return .unavailable(
                .init(
                    pluginID: plan.pluginID,
                    taskID: taskID,
                    taskURL: nil,
                    reason: .init(runtime: error)
                )
            )
        } catch {
            return .unavailable(
                .init(
                    pluginID: plan.pluginID,
                    taskID: taskID,
                    taskURL: nil,
                    reason: .transport(String(describing: error))
                )
            )
        }

        do {
            let response = try await transport.get(taskURL)
            guard (200..<300).contains(response.statusCode) else {
                return .unavailable(
                    .init(
                        pluginID: plan.pluginID,
                        taskID: taskID,
                        taskURL: taskURL,
                        reason: .httpStatus(response.statusCode)
                    )
                )
            }
            let payload = try JSONDecoder().decode(ProjectTrackerPluginTaskListPayload.self, from: response.body)
            guard let task = payload.tasks.first(where: { candidate in
                String(candidate.displayID ?? -1) == normalizedTaskID || String(candidate.id ?? -1) == normalizedTaskID
            }) else {
                return .unavailable(
                    .init(
                        pluginID: plan.pluginID,
                        taskID: taskID,
                        taskURL: taskURL,
                        reason: .notFound(taskID)
                    )
                )
            }
            return .available(
                .init(
                    pluginID: plan.pluginID,
                    taskID: taskID.trimmingCharacters(in: .whitespacesAndNewlines),
                    displayID: task.displayID,
                    projectID: task.projectID,
                    title: task.title ?? task.text,
                    status: task.status,
                    priority: task.priority
                )
            )
        } catch let error as DecodingError {
            return .unavailable(
                .init(
                    pluginID: plan.pluginID,
                    taskID: taskID,
                    taskURL: taskURL,
                    reason: .decoding(String(describing: error))
                )
            )
        } catch {
            return .unavailable(
                .init(
                    pluginID: plan.pluginID,
                    taskID: taskID,
                    taskURL: taskURL,
                    reason: .transport(String(describing: error))
                )
            )
        }
    }

    func taskStatusAdapterSnapshot(projectSlug: String, taskID: String) async -> PluginSupplementalStatus {
        switch await taskStatus(projectSlug: projectSlug, taskID: taskID) {
        case .available(let snapshot):
            return PluginSupplementalStatus(
                pluginID: snapshot.pluginID,
                adapterID: ProjectTrackerPlugin.taskStatusAdapterID,
                label: snapshot.statusLabel,
                detail: snapshot.statusDetail,
                severity: .info
            )
        case .unavailable(let unavailable):
            return PluginSupplementalStatus(
                pluginID: unavailable.pluginID,
                adapterID: ProjectTrackerPlugin.taskStatusAdapterID,
                label: "Project Tracker task unavailable",
                detail: unavailable.reason.statusDetail(taskID: unavailable.taskID, taskURL: unavailable.taskURL),
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

enum ProjectTrackerPluginTaskStatusResult: Equatable, Sendable {
    case available(ProjectTrackerPluginTaskStatusSnapshot)
    case unavailable(ProjectTrackerPluginTaskStatusUnavailable)
}

struct ProjectTrackerPluginTaskStatusSnapshot: Equatable, Sendable {
    let pluginID: String
    let taskID: String
    let displayID: Int?
    let projectID: String?
    let title: String?
    let status: String
    let priority: String?

    var statusLabel: String {
        let id = displayID.map { "#\($0)" } ?? taskID
        return "Project Tracker \(id): \(status)"
    }

    var statusDetail: String {
        [projectID, priority, title]
            .compactMap { value in
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return value
            }
            .joined(separator: " · ")
    }
}

struct ProjectTrackerPluginTaskStatusUnavailable: Equatable, Sendable {
    let pluginID: String
    let taskID: String
    let taskURL: URL?
    let reason: ProjectTrackerPluginTaskStatusUnavailableReason
}

enum ProjectTrackerPluginTaskStatusUnavailableReason: Equatable, Sendable {
    case invalidTaskID(String)
    case invalidProjectSlug(String)
    case notFound(String)
    case httpStatus(Int)
    case transport(String)
    case decoding(String)

    init(runtime error: ProjectTrackerPluginRuntimeError) {
        switch error {
        case .invalidProjectSlug(let projectSlug):
            self = .invalidProjectSlug(projectSlug)
        case .invalidTaskID(let taskID):
            self = .invalidTaskID(taskID)
        default:
            self = .transport(String(describing: error))
        }
    }

    func statusDetail(taskID: String, taskURL: URL?) -> String {
        switch self {
        case .invalidTaskID(let invalidTaskID):
            return "Invalid Project Tracker task id: \(invalidTaskID)"
        case .invalidProjectSlug(let projectSlug):
            return "Invalid Project Tracker project slug: \(projectSlug)"
        case .notFound(let taskID):
            return "Project Tracker task was not present in \(taskURL?.absoluteString ?? taskID)"
        case .httpStatus(let statusCode):
            return "HTTP \(statusCode) from \(taskURL?.absoluteString ?? taskID)"
        case .transport(let message):
            return "Transport failure from \(taskURL?.absoluteString ?? taskID): \(message)"
        case .decoding(let message):
            return "Could not decode Project Tracker task \(taskID): \(message)"
        }
    }
}

private struct ProjectTrackerPluginTaskListPayload: Decodable {
    let tasks: [ProjectTrackerPluginTaskPayload]
}

private struct ProjectTrackerPluginTaskPayload: Decodable {
    let id: Int?
    let displayID: Int?
    let projectID: String?
    let title: String?
    let text: String?
    let status: String
    let priority: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayID = "display_id"
        case projectID = "project_id"
        case title
        case text
        case status
        case priority
    }
}

enum ProjectTrackerPluginRuntimeError: Error, Equatable, CustomStringConvertible {
    case invalidProjectSlug(String)
    case invalidTaskID(String)
    case missingCommandArgument(String)
    case unknownCommand(String)

    var description: String {
        switch self {
        case .invalidProjectSlug(let slug):
            return "Project Tracker project slug is invalid: \(slug)"
        case .invalidTaskID(let taskID):
            return "Project Tracker task id is invalid: \(taskID)"
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
