import Foundation
import Darwin

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
        try await Self.listDirectories(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=10",
                "\(user)@\(host)",
                "ls", "-1", root,
            ],
            timeout: 15
        )
    }

    nonisolated static func listDirectories(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int = 1_048_576
    ) async throws -> [String] {
        let result = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try runProcess(
                        executableURL: executableURL,
                        arguments: arguments,
                        timeout: timeout,
                        maxOutputBytes: maxOutputBytes
                    )
                })
            }
        }

        guard result.exitCode == 0 else {
            let stderr = String(decoding: result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DiscoveryError.processFailed(exitCode: result.exitCode, stderr: stderr)
        }

        return String(decoding: result.stdout, as: UTF8.self)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    private nonisolated static func runProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in termination.signal() }
        try process.run()

        let stdout = ProcessOutputBox()
        let stderr = ProcessOutputBox()
        let readers = DispatchGroup()
        for (pipe, destination) in [(stdoutPipe, stdout), (stderrPipe, stderr)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                destination.read(
                    from: pipe.fileHandleForReading,
                    maxBytes: max(0, maxOutputBytes),
                    onLimitExceeded: { process.terminate() }
                )
                readers.leave()
            }
        }

        let boundedTimeout = max(0, timeout)
        let operationDeadline = DispatchTime.now() + boundedTimeout
        if termination.wait(timeout: operationDeadline) == .timedOut {
            process.terminate()
            if termination.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(timeout: .now() + 0.5)
            }
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            _ = readers.wait(timeout: .now() + 0.5)
            if stdout.limitExceeded {
                throw DiscoveryError.outputLimitExceeded(stream: "stdout", maxBytes: max(0, maxOutputBytes))
            }
            if stderr.limitExceeded {
                throw DiscoveryError.outputLimitExceeded(stream: "stderr", maxBytes: max(0, maxOutputBytes))
            }
            throw DiscoveryError.processTimedOut
        }

        if readers.wait(timeout: operationDeadline) == .timedOut {
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            _ = readers.wait(timeout: .now() + 0.5)
            throw DiscoveryError.processTimedOut
        }
        if stdout.limitExceeded {
            throw DiscoveryError.outputLimitExceeded(stream: "stdout", maxBytes: max(0, maxOutputBytes))
        }
        if stderr.limitExceeded {
            throw DiscoveryError.outputLimitExceeded(stream: "stderr", maxBytes: max(0, maxOutputBytes))
        }
        if let readFailure = stdout.readFailure {
            throw DiscoveryError.outputReadFailed(stream: "stdout", message: readFailure)
        }
        if let readFailure = stderr.readFailure {
            throw DiscoveryError.outputReadFailed(stream: "stderr", message: readFailure)
        }
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdout.value,
            stderr: stderr.value
        )
    }

    enum DiscoveryError: Error, Equatable {
        case processFailed(exitCode: Int32, stderr: String)
        case processTimedOut
        case outputLimitExceeded(stream: String, maxBytes: Int)
        case outputReadFailed(stream: String, message: String)
    }
}

private struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}

private final class ProcessOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var didExceedLimit = false
    private var failure: String?

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    var limitExceeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didExceedLimit
    }

    var readFailure: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    func read(
        from handle: FileHandle,
        maxBytes: Int,
        onLimitExceeded: () -> Void
    ) {
        do {
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                lock.lock()
                let remaining = max(0, maxBytes - data.count)
                if chunk.count > remaining {
                    data.append(chunk.prefix(remaining))
                    didExceedLimit = true
                    lock.unlock()
                    onLimitExceeded()
                    return
                }
                data.append(chunk)
                lock.unlock()
            }
        } catch {
            lock.lock()
            failure = String(describing: error)
            lock.unlock()
        }
    }
}
