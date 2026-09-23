import Foundation

@MainActor
class ProjectDiscoveryService {
    private var cachedProjects: [SessionProfile] = []
    private var lastRefresh: Date?
    private let configService: ConfigService

    init(configService: ConfigService) {
        self.configService = configService
    }

    /// Discover project directories from the configured source.
    /// Local discovery lists real directories under `projectDiscovery.root`.
    /// SSH discovery returns cached results on network failure.
    func discover() async -> [SessionProfile] {
        let config = configService.load()
        guard let discovery = config.projectDiscovery, discovery.enabled else {
            return cachedProjects
        }

        let defaults = config.sshDefaults ?? .default
        if discovery.connection == "local" || defaults.host.isEmpty || defaults.user.isEmpty {
            cachedProjects = profilesFromLocalProjectRoot(discovery)
            lastRefresh = Date()
            return cachedProjects
        }

        do {
            let dirs = try await listRemoteDirectories(
                host: defaults.host,
                user: defaults.user,
                root: discovery.root
            )
            cachedProjects = profilesFromDirectoryNames(dirs, discovery: discovery, defaults: defaults)
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

    func profilesFromLocalProjectRoot(_ discovery: ProjectDiscoveryConfig) -> [SessionProfile] {
        let rootURL = URL(fileURLWithPath: (discovery.root as NSString).expandingTildeInPath, isDirectory: true)
        let directoryNames = localDirectoryNames(in: rootURL)
        return directoryNames.map { dirName in
            SessionProfile(
                label: dirName,
                connection: .local,
                command: "/bin/zsh",
                directory: rootURL.appendingPathComponent(dirName, isDirectory: true).standardizedFileURL.path
            )
        }
    }

    private func localDirectoryNames(in rootURL: URL) -> [String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return url.lastPathComponent
        }.sorted()
    }

    private func listRemoteDirectories(host: String, user: String, root: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = [
                    "-o", "ConnectTimeout=10",
                    "\(user)@\(host)",
                    "ls", "-1", root
                ]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: DiscoveryError.sshFailed(exitCode: process.terminationStatus))
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let dirs = output.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .sorted()
                continuation.resume(returning: dirs)
            }
        }
    }

    enum DiscoveryError: Error {
        case sshFailed(exitCode: Int32)
    }
}
