import Foundation

enum PluginCapability: String, Codable, CaseIterable, Equatable, Sendable {
    case channelProvider = "channel-provider"
    case statusAdapter = "status-adapter"
    case commandProvider = "command-provider"
    case notificationProvider = "notification-provider"
    case storageProvider = "storage-provider"
}

enum PluginPermission: Hashable, Sendable {
    case networkLocalhost
    case networkHost(String)
    case filesystemPluginStorage
    case filesystemReadUserSelected
    case pluginNotifications
    case automationAppleEvents
}

extension PluginPermission: RawRepresentable {
    init?(rawValue: String) {
        switch rawValue {
        case "network:localhost":
            self = .networkLocalhost
        case "filesystem:plugin-storage":
            self = .filesystemPluginStorage
        case "filesystem:read-user-selected":
            self = .filesystemReadUserSelected
        case "notifications:plugin":
            self = .pluginNotifications
        case "automation:apple-events":
            self = .automationAppleEvents
        default:
            let prefix = "network:host:"
            guard rawValue.hasPrefix(prefix) else { return nil }
            let host = String(rawValue.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { return nil }
            self = .networkHost(host)
        }
    }

    var rawValue: String {
        switch self {
        case .networkLocalhost:
            return "network:localhost"
        case .networkHost(let host):
            return "network:host:\(host)"
        case .filesystemPluginStorage:
            return "filesystem:plugin-storage"
        case .filesystemReadUserSelected:
            return "filesystem:read-user-selected"
        case .pluginNotifications:
            return "notifications:plugin"
        case .automationAppleEvents:
            return "automation:apple-events"
        }
    }
}

extension PluginPermission: Codable {
    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        guard let permission = PluginPermission(rawValue: rawValue) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown plugin permission: \(rawValue)")
            )
        }
        self = permission
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct PluginEntrypoint: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case bundledSwift = "bundled-swift"
        case xpcService = "xpc-service"
    }

    let kind: Kind
    let bundleIdentifier: String?
}

struct PluginManifest: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let version: String
    let minimumHoloscapeVersion: String
    let capabilities: [PluginCapability]
    let permissions: [PluginPermission]
    let storageNamespace: String
    let entrypoint: PluginEntrypoint
}

struct ValidatedPluginManifest: Equatable, Sendable {
    let manifest: PluginManifest

    var id: String { manifest.id }
    var displayName: String { manifest.displayName }
    var capabilities: Set<PluginCapability> { Set(manifest.capabilities) }
    var permissions: Set<PluginPermission> { Set(manifest.permissions) }
    var storageNamespace: String { manifest.storageNamespace }
}

enum PluginManifestValidationError: Error, Equatable, CustomStringConvertible {
    case emptyID
    case emptyDisplayName
    case emptyVersion
    case emptyMinimumHoloscapeVersion
    case noCapabilities(String)
    case duplicateCapabilities(String, [PluginCapability])
    case duplicatePermissions(String, [PluginPermission])
    case emptyStorageNamespace(String)
    case invalidStorageNamespace(String, String)
    case coreStorageNamespaceCollision(String, String)
    case storagePermissionMissing(String)
    case notificationPermissionMissing(String)
    case emptyNetworkHost(String)

    var description: String {
        switch self {
        case .emptyID:
            return "Plugin manifest id must not be empty"
        case .emptyDisplayName:
            return "Plugin manifest displayName must not be empty"
        case .emptyVersion:
            return "Plugin manifest version must not be empty"
        case .emptyMinimumHoloscapeVersion:
            return "Plugin manifest minimumHoloscapeVersion must not be empty"
        case .noCapabilities(let id):
            return "Plugin \(id) must declare at least one capability"
        case .duplicateCapabilities(let id, let capabilities):
            return "Plugin \(id) declares duplicate capabilities: \(capabilities.map(\.rawValue).joined(separator: ", "))"
        case .duplicatePermissions(let id, let permissions):
            return "Plugin \(id) declares duplicate permissions: \(permissions.map(\.rawValue).joined(separator: ", "))"
        case .emptyStorageNamespace(let id):
            return "Plugin \(id) storageNamespace must not be empty"
        case .invalidStorageNamespace(let id, let namespace):
            return "Plugin \(id) storageNamespace is invalid: \(namespace)"
        case .coreStorageNamespaceCollision(let id, let namespace):
            return "Plugin \(id) storageNamespace collides with core storage: \(namespace)"
        case .storagePermissionMissing(let id):
            return "Plugin \(id) declares storage-backed capabilities without filesystem:plugin-storage"
        case .notificationPermissionMissing(let id):
            return "Plugin \(id) declares notification-provider without notifications:plugin"
        case .emptyNetworkHost(let id):
            return "Plugin \(id) declares an empty network:host permission"
        }
    }
}

struct PluginManifestValidator {
    static let coreStorageNamespaces: Set<String> = [
        "config",
        "sessions",
        "scrollback",
        "skins",
        "crash-reports",
    ]

    func validate(_ manifest: PluginManifest) throws -> ValidatedPluginManifest {
        let id = manifest.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw PluginManifestValidationError.emptyID }
        guard !manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginManifestValidationError.emptyDisplayName
        }
        guard !manifest.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginManifestValidationError.emptyVersion
        }
        guard !manifest.minimumHoloscapeVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginManifestValidationError.emptyMinimumHoloscapeVersion
        }
        guard !manifest.capabilities.isEmpty else {
            throw PluginManifestValidationError.noCapabilities(id)
        }

        let duplicateCapabilities = duplicates(in: manifest.capabilities)
        guard duplicateCapabilities.isEmpty else {
            throw PluginManifestValidationError.duplicateCapabilities(id, duplicateCapabilities)
        }
        let duplicatePermissions = duplicates(in: manifest.permissions)
        guard duplicatePermissions.isEmpty else {
            throw PluginManifestValidationError.duplicatePermissions(id, duplicatePermissions)
        }

        let namespace = manifest.storageNamespace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !namespace.isEmpty else {
            throw PluginManifestValidationError.emptyStorageNamespace(id)
        }
        guard isValidStorageNamespace(namespace) else {
            throw PluginManifestValidationError.invalidStorageNamespace(id, manifest.storageNamespace)
        }
        guard !Self.coreStorageNamespaces.contains(namespace) else {
            throw PluginManifestValidationError.coreStorageNamespaceCollision(id, namespace)
        }

        for permission in manifest.permissions {
            if case .networkHost(let host) = permission, host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw PluginManifestValidationError.emptyNetworkHost(id)
            }
        }

        let capabilities = Set(manifest.capabilities)
        let permissions = Set(manifest.permissions)
        if capabilities.contains(.storageProvider) && !permissions.contains(.filesystemPluginStorage) {
            throw PluginManifestValidationError.storagePermissionMissing(id)
        }
        if capabilities.contains(.notificationProvider) && !permissions.contains(.pluginNotifications) {
            throw PluginManifestValidationError.notificationPermissionMissing(id)
        }

        return ValidatedPluginManifest(manifest: manifest)
    }

    private func isValidStorageNamespace(_ namespace: String) -> Bool {
        let pattern = #"^[a-z0-9][a-z0-9-]{0,62}$"#
        return namespace.range(of: pattern, options: .regularExpression) != nil
    }

    private func duplicates<T: Hashable>(in values: [T]) -> [T] {
        var seen = Set<T>()
        var duplicates: [T] = []
        for value in values {
            if !seen.insert(value).inserted && !duplicates.contains(value) {
                duplicates.append(value)
            }
        }
        return duplicates
    }
}
