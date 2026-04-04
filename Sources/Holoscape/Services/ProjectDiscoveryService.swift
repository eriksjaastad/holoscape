import Foundation

@MainActor
class ProjectDiscoveryService {
    private var cachedProjects: [SessionProfile] = []
    private var lastRefresh: Date?
    private let configService: ConfigService

    init(configService: ConfigService) {
        self.configService = configService
    }

    /// Discover project directories on the remote host.
    /// Returns cached results on SSH failure.
    func discover() async -> [SessionProfile] {
        let config = configService.load()
        guard let discovery = config.projectDiscovery, discovery.enabled,
              let defaults = config.sshDefaults,
              !defaults.host.isEmpty, !defaults.user.isEmpty else {
            return cachedProjects
        }

        do {
            let dirs = try await listRemoteDirectories(
                host: defaults.host,
                user: defaults.user,
                root: discovery.root
            )
            cachedProjects = dirs.map { dirName in
                SessionProfile(
                    label: dirName,
                    connection: .ssh,
                    command: discovery.command,
                    directory: "\(discovery.root)/\(dirName)",
                    host: defaults.host,
                    user: defaults.user
                )
            }
            lastRefresh = Date()
            return cachedProjects
        } catch {
            NSLog("ProjectDiscovery: SSH failed (\(error)). Using cache.")
            return cachedProjects
        }
    }

    /// Force refresh, clearing cache first.
    func refresh() async -> [SessionProfile] {
        cachedProjects = []
        return await discover()
    }

    /// Return cached projects without SSH call.
    func cached() -> [SessionProfile] {
        return cachedProjects
    }

    // MARK: - Internal (exposed for testing)

    func profilesFromDirectoryNames(_ dirs: [String], discovery: ProjectDiscoveryConfig, defaults: SSHDefaults) -> [SessionProfile] {
        return dirs.map { dirName in
            SessionProfile(
                label: dirName,
                connection: .ssh,
                command: discovery.command,
                directory: "\(discovery.root)/\(dirName)",
                host: defaults.host,
                user: defaults.user
            )
        }
    }

    private func listRemoteDirectories(host: String, user: String, root: String) async throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["\(user)@\(host)", "ls -1 \(root)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DiscoveryError.sshFailed(exitCode: process.terminationStatus)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    enum DiscoveryError: Error {
        case sshFailed(exitCode: Int32)
    }
}
