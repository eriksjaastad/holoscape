import Foundation

struct PluginStorageService {
    private let rootDirectory: URL
    private let fileManager: FileManager

    init(
        rootDirectory: URL = PluginStorageService.defaultRootDirectory(),
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    func storageDirectory(
        for plan: ProjectTrackerPluginRuntimePlan,
        createIfNeeded: Bool = false
    ) throws -> URL {
        guard plan.permissions.contains(.filesystemPluginStorage) else {
            throw PluginStorageError.permissionMissing(plan.pluginID, .filesystemPluginStorage)
        }
        guard isValidStorageNamespace(plan.storageNamespace) else {
            throw PluginStorageError.invalidStorageNamespace(plan.pluginID, plan.storageNamespace)
        }

        let pluginsRoot = rootDirectory.appendingPathComponent("plugins", isDirectory: true)
        let storageURL = pluginsRoot.appendingPathComponent(plan.storageNamespace, isDirectory: true)
        guard storageURL.standardizedFileURL.path.hasPrefix(pluginsRoot.standardizedFileURL.path + "/") else {
            throw PluginStorageError.storageEscapedRoot(plan.pluginID, storageURL.path)
        }

        if createIfNeeded {
            try fileManager.createDirectory(
                at: storageURL,
                withIntermediateDirectories: true
            )
        }
        return storageURL
    }

    private static func defaultRootDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["HOLOSCAPE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".holoscape")
    }

    private func isValidStorageNamespace(_ namespace: String) -> Bool {
        namespace.range(of: #"^[a-z0-9][a-z0-9-]{0,62}$"#, options: .regularExpression) != nil
    }
}

enum PluginStorageError: Error, Equatable, CustomStringConvertible, Sendable {
    case permissionMissing(String, PluginPermission)
    case invalidStorageNamespace(String, String)
    case storageEscapedRoot(String, String)

    var description: String {
        switch self {
        case .permissionMissing(let pluginID, let permission):
            return "Plugin \(pluginID) cannot access plugin storage without \(permission.rawValue)"
        case .invalidStorageNamespace(let pluginID, let namespace):
            return "Plugin \(pluginID) storage namespace is invalid: \(namespace)"
        case .storageEscapedRoot(let pluginID, let path):
            return "Plugin \(pluginID) storage path escapes plugin root: \(path)"
        }
    }
}
