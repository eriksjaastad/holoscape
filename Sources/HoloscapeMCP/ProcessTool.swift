import Darwin
import Foundation
import MCP

struct ProcessToolRequest: Sendable {
    let command: String
    let workingDirectory: String?
    let environment: [String: String]
    let timeoutSeconds: Double
}

struct ProcessToolResult: Sendable {
    let command: String
    let workingDirectory: String?
    let exitCode: Int32?
    let timedOut: Bool
    let stdout: String
    let stderr: String
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
    /// Whether process-group signaling and output-pipe closure completed.
    /// Descendants that deliberately leave the group are outside this contract.
    let processGroupCleanupSucceeded: Bool?
}

enum ProcessToolError: LocalizedError {
    case missingCommand
    case invalidTimeout
    case invalidWorkingDirectory(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCommand:
            return "Missing 'command' parameter"
        case .invalidTimeout:
            return "timeoutSeconds must be greater than 0"
        case .invalidWorkingDirectory(let path):
            return "Working directory does not exist or is not a directory: \(path)"
        case .launchFailed(let reason):
            return "Failed to launch process: \(reason)"
        }
    }
}

final class ProcessToolOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var byteCount = 0
    private var didTruncate = false
    private let maxBytes: Int

    init(maxBytes: Int = .max) {
        self.maxBytes = max(0, maxBytes)
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        let remaining = max(0, maxBytes - byteCount)
        if data.count > remaining {
            if remaining > 0 {
                chunks.append(data.prefix(remaining))
                byteCount += remaining
            }
            didTruncate = true
        } else {
            chunks.append(data)
            byteCount += data.count
        }
        lock.unlock()
    }

    func snapshot() -> (string: String, truncated: Bool) {
        lock.lock()
        let data = chunks.reduce(into: Data()) { partial, chunk in
            partial.append(chunk)
        }
        let truncated = didTruncate
        lock.unlock()
        return (
            String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self),
            truncated
        )
    }

    func string() -> String {
        snapshot().string
    }
}

final class ProcessToolCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return false }
        didFinish = true
        return true
    }
}

enum ProcessToolControllerStatus: Equatable {
    case completed(exitCode: Int32)
    case timedOut(groupCleanupSucceeded: Bool)
    case launchFailed(String)
}

func parseProcessToolControllerStatus(_ text: String) -> ProcessToolControllerStatus? {
    let status = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if status.hasPrefix("completed:"),
       let exitCode = Int32(status.dropFirst("completed:".count)) {
        return .completed(exitCode: exitCode)
    }
    if status == "timedOut:groupSignaled" {
        return .timedOut(groupCleanupSucceeded: true)
    }
    if status == "timedOut:groupSignalFailed" {
        return .timedOut(groupCleanupSucceeded: false)
    }
    if status.hasPrefix("launchFailed:") {
        return .launchFailed(String(status.dropFirst("launchFailed:".count)))
    }
    return nil
}

private func writeProcessToolStatus(_ status: String, to path: String) {
    do {
        try Data(status.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
        FileHandle.standardError.write(Data("Failed to write process status: \(error.localizedDescription)\n".utf8))
    }
}

/// Launches the shell as the leader of a fresh process group. The controller
/// deliberately leaves this direct child waitable until cleanup signals have
/// been sent, so its PID cannot be reused as an unrelated process-group ID.
private func spawnProcessToolShell(command: String) throws -> pid_t {
    var fileActions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&fileActions) == 0,
          posix_spawnattr_init(&attributes) == 0 else {
        throw ProcessToolError.launchFailed("Could not initialize shell launch attributes")
    }
    defer {
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attributes)
    }

    guard posix_spawn_file_actions_addopen(
        &fileActions,
        STDIN_FILENO,
        "/dev/null",
        O_RDONLY,
        0
    ) == 0,
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
    posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
        throw ProcessToolError.launchFailed("Could not configure shell process group")
    }

    var spawnedPID: pid_t = 0
    let result = "/bin/zsh".withCString { shellPointer in
        "-lc".withCString { flagPointer in
            command.withCString { commandPointer in
                var arguments: [UnsafeMutablePointer<CChar>?] = [
                    UnsafeMutablePointer(mutating: shellPointer),
                    UnsafeMutablePointer(mutating: flagPointer),
                    UnsafeMutablePointer(mutating: commandPointer),
                    nil,
                ]
                return arguments.withUnsafeMutableBufferPointer { buffer in
                    posix_spawn(
                        &spawnedPID,
                        shellPointer,
                        &fileActions,
                        &attributes,
                        buffer.baseAddress!,
                        environ
                    )
                }
            }
        }
    }
    guard result == 0 else {
        throw ProcessToolError.launchFailed(String(cString: strerror(result)))
    }
    return spawnedPID
}

private func processToolExitCode(from waitStatus: Int32) -> Int32 {
    let signal = waitStatus & 0x7f
    return signal == 0 ? (waitStatus >> 8) & 0xff : signal
}

private func waitForProcessToolChild(_ pid: pid_t) -> Result<Int32, ProcessToolError> {
    var waitStatus: Int32 = 0
    while true {
        if waitpid(pid, &waitStatus, 0) == pid {
            return .success(processToolExitCode(from: waitStatus))
        }
        if errno != EINTR {
            return .failure(.launchFailed("Could not wait for child process: \(String(cString: strerror(errno)))"))
        }
    }
}

private func processToolChildHasExited(_ pid: pid_t) -> Result<Bool, ProcessToolError> {
    var information = siginfo_t()
    while true {
        let result = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
        if result == 0 {
            return .success(information.si_pid == pid)
        }
        if errno != EINTR {
            return .failure(.launchFailed("Could not inspect child process: \(String(cString: strerror(errno)))"))
        }
    }
}

/// Sends bounded TERM-to-KILL escalation while the unreaped group leader still
/// reserves the numeric process-group ID. This proves signals target the owned
/// group; it does not claim to contain descendants that deliberately call setsid.
private func terminateProcessToolGroup(_ processGroupID: pid_t) -> Bool {
    if Darwin.kill(-processGroupID, SIGTERM) == -1 {
        // With an owned, unreaped leader, EPERM means the group has no
        // signalable live members (the remaining member is the zombie leader).
        return errno == ESRCH || errno == EPERM
    }

    usleep(250_000)
    if Darwin.kill(-processGroupID, SIGKILL) == -1 {
        return errno == ESRCH || errno == EPERM
    }
    usleep(50_000)
    return true
}

private func drainProcessToolPipe(
    _ handle: FileHandle,
    into buffer: ProcessToolOutputBuffer
) -> Bool {
    let descriptor = handle.fileDescriptor
    let currentFlags = fcntl(descriptor, F_GETFL)
    guard currentFlags != -1,
          fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK) != -1 else {
        try? handle.close()
        return false
    }

    var bytes = [UInt8](repeating: 0, count: 8_192)
    let deadline = DispatchTime.now() + .milliseconds(100)
    while DispatchTime.now() < deadline {
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count > 0 {
            buffer.append(Data(bytes.prefix(count)))
            continue
        }
        if count == 0 {
            try? handle.close()
            return true
        }
        let readError = errno
        if readError == EINTR { continue }
        if readError == EAGAIN || readError == EWOULDBLOCK {
            usleep(1_000)
            continue
        }
        try? handle.close()
        return false
    }
    try? handle.close()
    return false
}

/// Owns timeout arbitration outside the command's process group. The direct
/// shell remains an unreaped child until cleanup finishes, preventing PGID reuse
/// between timeout detection and group signaling.
func runProcessToolController(
    command: String,
    timeoutSeconds: Double,
    statusPath: String
) -> Never {
    let shellPID: pid_t
    do {
        shellPID = try spawnProcessToolShell(command: command)
    } catch {
        writeProcessToolStatus("launchFailed:\(error.localizedDescription)", to: statusPath)
        Darwin.exit(127)
    }

    let deadline = DispatchTime.now() + timeoutSeconds
    var timedOut = false
    var inspectionFailure: ProcessToolError?
    while true {
        switch processToolChildHasExited(shellPID) {
        case .success(true):
            break
        case .success(false):
            if DispatchTime.now() >= deadline {
                timedOut = true
                break
            }
            usleep(5_000)
            continue
        case .failure(let error):
            inspectionFailure = error
        }
        break
    }

    let groupCleanupSucceeded = terminateProcessToolGroup(shellPID)
    let childResult = waitForProcessToolChild(shellPID)

    if let inspectionFailure {
        writeProcessToolStatus("launchFailed:\(inspectionFailure.localizedDescription)", to: statusPath)
        Darwin.exit(125)
    }
    guard case .success(let exitCode) = childResult else {
        let reason: String
        if case .failure(let error) = childResult {
            reason = error.localizedDescription
        } else {
            reason = "Unknown child wait failure"
        }
        writeProcessToolStatus("launchFailed:\(reason)", to: statusPath)
        Darwin.exit(125)
    }

    if timedOut {
        writeProcessToolStatus(
            groupCleanupSucceeded ? "timedOut:groupSignaled" : "timedOut:groupSignalFailed",
            to: statusPath
        )
    } else if groupCleanupSucceeded {
        writeProcessToolStatus("completed:\(exitCode)", to: statusPath)
    } else {
        writeProcessToolStatus("launchFailed:Completed command process-group cleanup signaling failed", to: statusPath)
    }
    Darwin.exit(0)
}

func processToolRequest(from args: [String: Value]) throws -> ProcessToolRequest {
    guard let command = args["command"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
          !command.isEmpty else {
        throw ProcessToolError.missingCommand
    }

    let timeout = args["timeoutSeconds"]?.doubleValue
        ?? args["timeoutSeconds"]?.intValue.map(Double.init)
        ?? 30
    guard timeout > 0 else {
        throw ProcessToolError.invalidTimeout
    }

    var environment: [String: String] = [:]
    if let envObject = args["env"]?.objectValue {
        for (key, value) in envObject {
            if let string = value.stringValue {
                environment[key] = string
            }
        }
    }

    return ProcessToolRequest(
        command: command,
        workingDirectory: args["workingDirectory"]?.stringValue ?? args["dir"]?.stringValue,
        environment: environment,
        timeoutSeconds: timeout
    )
}

func runProcessTool(
    _ request: ProcessToolRequest,
    maxOutputBytes: Int = 1_048_576,
    launcherExecutableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0])
) async throws -> ProcessToolResult {
    let process = Process()
    let statusURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("holoscape-process-tool-\(UUID().uuidString).status")
    process.executableURL = launcherExecutableURL
    process.arguments = [
        "--holoscape-process-controller",
        request.command,
        String(request.timeoutSeconds),
        statusURL.path,
    ]

    if let workingDirectory = request.workingDirectory, !workingDirectory.isEmpty {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProcessToolError.invalidWorkingDirectory(workingDirectory)
        }
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
    }

    if !request.environment.isEmpty {
        var env = ProcessInfo.processInfo.environment
        request.environment.forEach { key, value in env[key] = value }
        process.environment = env
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let stdout = ProcessToolOutputBuffer(maxBytes: maxOutputBytes)
    let stderr = ProcessToolOutputBuffer(maxBytes: maxOutputBytes)

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        stdout.append(handle.availableData)
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        stderr.append(handle.availableData)
    }

    return try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { _ in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            let stdoutClosed = drainProcessToolPipe(stdoutPipe.fileHandleForReading, into: stdout)
            let stderrClosed = drainProcessToolPipe(stderrPipe.fileHandleForReading, into: stderr)
            let outputPipesClosed = stdoutClosed && stderrClosed
            let standardOutput = stdout.snapshot()
            let standardError = stderr.snapshot()
            let status = try? String(contentsOf: statusURL, encoding: .utf8)
            try? FileManager.default.removeItem(at: statusURL)
            guard let status, let parsed = parseProcessToolControllerStatus(status) else {
                continuation.resume(throwing: ProcessToolError.launchFailed("Controller exited without a valid status"))
                return
            }

            switch parsed {
            case .completed(let exitCode):
                continuation.resume(returning: ProcessToolResult(
                    command: request.command,
                    workingDirectory: request.workingDirectory,
                    exitCode: exitCode,
                    timedOut: false,
                    stdout: standardOutput.string,
                    stderr: standardError.string,
                    stdoutTruncated: standardOutput.truncated,
                    stderrTruncated: standardError.truncated,
                    processGroupCleanupSucceeded: outputPipesClosed ? nil : false
                ))
            case .timedOut(let groupCleanupSucceeded):
                continuation.resume(returning: ProcessToolResult(
                    command: request.command,
                    workingDirectory: request.workingDirectory,
                    exitCode: nil,
                    timedOut: true,
                    stdout: standardOutput.string,
                    stderr: standardError.string,
                    stdoutTruncated: standardOutput.truncated,
                    stderrTruncated: standardError.truncated,
                    processGroupCleanupSucceeded: groupCleanupSucceeded && outputPipesClosed
                ))
            case .launchFailed(let reason):
                continuation.resume(throwing: ProcessToolError.launchFailed(reason))
            }
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? FileManager.default.removeItem(at: statusURL)
            continuation.resume(throwing: ProcessToolError.launchFailed(error.localizedDescription))
        }
    }
}

func formatProcessToolResult(_ result: ProcessToolResult) -> String {
    var lines: [String] = []
    lines.append("command: \(result.command)")
    if let workingDirectory = result.workingDirectory {
        lines.append("workingDirectory: \(workingDirectory)")
    }
    if result.timedOut {
        lines.append("timedOut: true")
    } else {
        lines.append("exitCode: \(result.exitCode ?? -1)")
    }
    if result.stdoutTruncated {
        lines.append("stdoutTruncated: true")
    }
    if result.stderrTruncated {
        lines.append("stderrTruncated: true")
    }
    if result.processGroupCleanupSucceeded == false {
        lines.append("processGroupCleanupSucceeded: false")
    }
    lines.append("stdout:")
    lines.append(result.stdout.isEmpty ? "(empty)" : result.stdout)
    lines.append("stderr:")
    lines.append(result.stderr.isEmpty ? "(empty)" : result.stderr)
    return lines.joined(separator: "\n")
}
