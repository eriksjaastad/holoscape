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
    let processCleanupConfirmed: Bool?
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
    enum TimeoutClaim: Equatable {
        case unclaimed
        case processExited
        case timedOut
    }

    private let lock = NSLock()
    private var didFinish = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return false }
        didFinish = true
        return true
    }

    func claimTimeout(isRunning: () -> Bool) -> TimeoutClaim {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish, isRunning() else { return .unclaimed }
        didFinish = true
        return isRunning() ? .timedOut : .processExited
    }
}

enum ProcessToolControllerStatus: Equatable {
    case completed(exitCode: Int32)
    case timedOut(cleanupConfirmed: Bool)
    case launchFailed(String)
}

func parseProcessToolControllerStatus(_ text: String) -> ProcessToolControllerStatus? {
    let status = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if status.hasPrefix("completed:"),
       let exitCode = Int32(status.dropFirst("completed:".count)) {
        return .completed(exitCode: exitCode)
    }
    if status == "timedOut:confirmed" {
        return .timedOut(cleanupConfirmed: true)
    }
    if status == "timedOut:unconfirmed" {
        return .timedOut(cleanupConfirmed: false)
    }
    if status.hasPrefix("launchFailed:") {
        return .launchFailed(String(status.dropFirst("launchFailed:".count)))
    }
    return nil
}

private final class ProcessToolAnchorState: @unchecked Sendable {
    private let lock = NSLock()
    private var terminating = false

    func beginTermination() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminating else { return false }
        terminating = true
        return true
    }

    func isTerminating() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminating
    }
}

private func processToolNoopSignalHandler(_: Int32) {}

private func writeProcessToolStatus(_ status: String, to path: String) {
    do {
        try Data(status.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
        FileHandle.standardError.write(Data("Failed to write process status: \(error.localizedDescription)\n".utf8))
    }
}

private func spawnProcessToolShell(command: String, processGroupID: pid_t) throws -> pid_t {
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
    posix_spawnattr_setpgroup(&attributes, processGroupID) == 0 else {
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

private func spawnProcessToolShellRunner(
    command: String,
    commandStatusPath: String,
    processGroupID: pid_t
) throws -> pid_t {
    var fileActions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&fileActions) == 0,
          posix_spawnattr_init(&attributes) == 0 else {
        throw ProcessToolError.launchFailed("Could not initialize shell runner launch attributes")
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
    posix_spawnattr_setpgroup(&attributes, processGroupID) == 0 else {
        throw ProcessToolError.launchFailed("Could not configure shell runner process group")
    }

    var spawnedPID: pid_t = 0
    let executablePath = CommandLine.arguments[0]
    let result = executablePath.withCString { executablePointer in
        "--holoscape-process-shell-runner".withCString { modePointer in
            command.withCString { commandPointer in
                commandStatusPath.withCString { statusPointer in
                    var arguments: [UnsafeMutablePointer<CChar>?] = [
                        UnsafeMutablePointer(mutating: executablePointer),
                        UnsafeMutablePointer(mutating: modePointer),
                        UnsafeMutablePointer(mutating: commandPointer),
                        UnsafeMutablePointer(mutating: statusPointer),
                        nil,
                    ]
                    return arguments.withUnsafeMutableBufferPointer { buffer in
                        posix_spawn(
                            &spawnedPID,
                            executablePointer,
                            &fileActions,
                            &attributes,
                            buffer.baseAddress!,
                            environ
                        )
                    }
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
        try? handle.close()
        return false
    }
    try? handle.close()
    return false
}

/// Keeps the command's direct parent separate from the process-group anchor.
/// If a command terminates its parent, the anchor still reserves the group ID
/// and the controller can safely order cleanup through the anchor capability.
func runProcessToolShellRunner(command: String, commandStatusPath: String) -> Never {
    let shellPID: pid_t
    do {
        shellPID = try spawnProcessToolShell(command: command, processGroupID: getpgrp())
    } catch {
        writeProcessToolStatus("launchFailed:\(error.localizedDescription)", to: commandStatusPath)
        Darwin.exit(127)
    }

    switch waitForProcessToolChild(shellPID) {
    case .success(let exitCode):
        writeProcessToolStatus("completed:\(exitCode)", to: commandStatusPath)
    case .failure(let error):
        writeProcessToolStatus("launchFailed:\(error.localizedDescription)", to: commandStatusPath)
    }
    Darwin.exit(0)
}

/// Runs inside a dedicated session and remains its process-group anchor until the
/// controller orders cleanup. The final SIGKILL includes this process, so the
/// numeric group ID cannot be reused between validation and signaling.
func runProcessToolAnchor(command: String, commandStatusPath: String) -> Never {
    guard getpgrp() == getpid() || setsid() != -1 else {
        writeProcessToolStatus("launchFailed:Could not establish dedicated process session", to: commandStatusPath)
        Darwin.exit(126)
    }

    _ = Darwin.signal(SIGTERM, processToolNoopSignalHandler)
    let state = ProcessToolAnchorState()
    let shellRunnerPID: pid_t
    do {
        shellRunnerPID = try spawnProcessToolShellRunner(
            command: command,
            commandStatusPath: commandStatusPath,
            processGroupID: getpgrp()
        )
    } catch {
        writeProcessToolStatus("launchFailed:\(error.localizedDescription)", to: commandStatusPath)
        Darwin.exit(127)
    }

    DispatchQueue.global(qos: .userInitiated).async {
        var commandByte: UInt8 = 0
        let bytesRead = Darwin.read(STDIN_FILENO, &commandByte, 1)
        guard bytesRead == 1 || bytesRead == 0 else { return }
        guard state.beginTermination() else { return }

        let processGroupID = getpgrp()
        _ = Darwin.kill(-processGroupID, SIGTERM)
        usleep(250_000)
        _ = Darwin.kill(-processGroupID, SIGKILL)
        Darwin._exit(125)
    }

    let runnerResult = waitForProcessToolChild(shellRunnerPID)
    guard !state.isTerminating() else {
        while true { pause() }
    }

    if !FileManager.default.fileExists(atPath: commandStatusPath) {
        let reason: String
        switch runnerResult {
        case .success:
            reason = "Shell runner exited without reporting command status"
        case .failure(let error):
            reason = error.localizedDescription
        }
        writeProcessToolStatus("launchFailed:\(reason)", to: commandStatusPath)
    }
    while true { pause() }
}

private func requestProcessToolAnchorCleanup(
    process: Process,
    control: FileHandle,
    timeoutMilliseconds: Int = 2_000
) -> Bool {
    do {
        try control.write(contentsOf: Data([1]))
    } catch {
        return false
    }

    let deadline = DispatchTime.now() + .milliseconds(timeoutMilliseconds)
    while process.isRunning, DispatchTime.now() < deadline {
        usleep(10_000)
    }
    return !process.isRunning
}

/// Owns timeout arbitration outside the command's process group. It only sends
/// cleanup through the anchor's pipe while that anchor is alive; it never signals
/// a process group by a previously observed PID.
func runProcessToolController(
    command: String,
    timeoutSeconds: Double,
    statusPath: String,
    launcherExecutableURL: URL = URL(fileURLWithPath: CommandLine.arguments[0])
) -> Never {
    _ = Darwin.signal(SIGPIPE, SIG_IGN)
    let commandStatusPath = statusPath + ".command"
    try? FileManager.default.removeItem(atPath: commandStatusPath)

    let anchor = Process()
    let controlPipe = Pipe()
    anchor.executableURL = launcherExecutableURL
    anchor.arguments = ["--holoscape-process-anchor", command, commandStatusPath]
    anchor.standardInput = controlPipe
    anchor.standardOutput = FileHandle.standardOutput
    anchor.standardError = FileHandle.standardError

    do {
        try anchor.run()
        try? controlPipe.fileHandleForReading.close()
    } catch {
        writeProcessToolStatus("launchFailed:\(error.localizedDescription)", to: statusPath)
        Darwin.exit(127)
    }

    let deadline = DispatchTime.now() + timeoutSeconds
    var commandStatus: ProcessToolControllerStatus?
    while DispatchTime.now() < deadline {
        if let data = FileManager.default.contents(atPath: commandStatusPath),
           let text = String(data: data, encoding: .utf8),
           let parsed = parseProcessToolControllerStatus(text) {
            commandStatus = parsed
            break
        }
        if !anchor.isRunning { break }
        usleep(5_000)
    }

    if case .completed(let exitCode) = commandStatus {
        let cleanupConfirmed = requestProcessToolAnchorCleanup(
            process: anchor,
            control: controlPipe.fileHandleForWriting
        )
        try? controlPipe.fileHandleForWriting.close()
        try? FileManager.default.removeItem(atPath: commandStatusPath)
        guard cleanupConfirmed else {
            writeProcessToolStatus("launchFailed:Completed command process group cleanup could not be confirmed", to: statusPath)
            Darwin.exit(125)
        }
        writeProcessToolStatus("completed:\(exitCode)", to: statusPath)
        Darwin.exit(0)
    }

    if case .launchFailed(let reason) = commandStatus {
        let cleanupConfirmed = requestProcessToolAnchorCleanup(
            process: anchor,
            control: controlPipe.fileHandleForWriting
        )
        try? controlPipe.fileHandleForWriting.close()
        try? FileManager.default.removeItem(atPath: commandStatusPath)
        let suffix = cleanupConfirmed ? "" : "; process cleanup could not be confirmed"
        writeProcessToolStatus("launchFailed:\(reason)\(suffix)", to: statusPath)
        Darwin.exit(127)
    }

    if commandStatus == nil, !anchor.isRunning, DispatchTime.now() < deadline {
        try? controlPipe.fileHandleForWriting.close()
        try? FileManager.default.removeItem(atPath: commandStatusPath)
        writeProcessToolStatus(
            "launchFailed:Process-group anchor exited before reporting command status",
            to: statusPath
        )
        Darwin.exit(125)
    }

    let cleanupConfirmed = anchor.isRunning && requestProcessToolAnchorCleanup(
        process: anchor,
        control: controlPipe.fileHandleForWriting
    )
    try? controlPipe.fileHandleForWriting.close()
    try? FileManager.default.removeItem(atPath: commandStatusPath)
    writeProcessToolStatus(
        cleanupConfirmed ? "timedOut:confirmed" : "timedOut:unconfirmed",
        to: statusPath
    )
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
                    processCleanupConfirmed: outputPipesClosed ? nil : false
                ))
            case .timedOut(let cleanupConfirmed):
                continuation.resume(returning: ProcessToolResult(
                    command: request.command,
                    workingDirectory: request.workingDirectory,
                    exitCode: nil,
                    timedOut: true,
                    stdout: standardOutput.string,
                    stderr: standardError.string,
                    stdoutTruncated: standardOutput.truncated,
                    stderrTruncated: standardError.truncated,
                    processCleanupConfirmed: cleanupConfirmed && outputPipesClosed
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
    if result.processCleanupConfirmed == false {
        lines.append("processCleanupConfirmed: false")
    }
    lines.append("stdout:")
    lines.append(result.stdout.isEmpty ? "(empty)" : result.stdout)
    lines.append("stderr:")
    lines.append(result.stderr.isEmpty ? "(empty)" : result.stderr)
    return lines.joined(separator: "\n")
}
