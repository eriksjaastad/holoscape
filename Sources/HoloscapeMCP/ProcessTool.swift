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

private struct ProcessToolProcessIdentity: Hashable, Sendable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    init(pid: pid_t, info: proc_bsdinfo) {
        self.pid = pid
        startSeconds = info.pbi_start_tvsec
        startMicroseconds = info.pbi_start_tvusec
    }
}

private enum ProcessToolIdentityLookup {
    case found(ProcessToolProcessIdentity)
    case missing
    case unavailable
}

private enum ProcessToolIdentityState: Equatable {
    case matching
    case goneOrReused
    case unavailable
}

private func processToolIdentity(for pid: pid_t) -> ProcessToolIdentityLookup {
    var info = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize) == expectedSize {
        return .found(ProcessToolProcessIdentity(pid: pid, info: info))
    }

    errno = 0
    if Darwin.kill(pid, 0) == -1, errno == ESRCH {
        return .missing
    }
    return .unavailable
}

private func processToolState(of identity: ProcessToolProcessIdentity) -> ProcessToolIdentityState {
    switch processToolIdentity(for: identity.pid) {
    case .found(let current):
        return current == identity ? .matching : .goneOrReused
    case .missing:
        return .goneOrReused
    case .unavailable:
        return .unavailable
    }
}

private func processToolGroupExists(_ processGroupID: pid_t) -> Bool? {
    errno = 0
    if Darwin.kill(-processGroupID, 0) == 0 { return true }
    return errno == ESRCH ? false : nil
}

private func terminateProcessToolGroup(
    rootedAt root: ProcessToolProcessIdentity,
    gracePeriodMilliseconds: Int = 250
) -> Bool {
    switch processToolState(of: root) {
    case .matching:
        guard getpgid(root.pid) == root.pid else { return false }
    case .goneOrReused:
        return processToolGroupExists(root.pid) == false
    case .unavailable:
        return false
    }

    if Darwin.kill(-root.pid, SIGTERM) == -1, errno != ESRCH { return false }
    let termDeadline = DispatchTime.now() + .milliseconds(gracePeriodMilliseconds)
    while DispatchTime.now() < termDeadline {
        guard let exists = processToolGroupExists(root.pid) else { return false }
        guard exists else { return true }
        usleep(10_000)
    }

    if Darwin.kill(-root.pid, SIGKILL) == -1, errno != ESRCH { return false }
    let killDeadline = DispatchTime.now() + .milliseconds(gracePeriodMilliseconds)
    while DispatchTime.now() < killDeadline {
        guard let exists = processToolGroupExists(root.pid) else { return false }
        guard exists else { return true }
        usleep(10_000)
    }
    return processToolGroupExists(root.pid) == false
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
    terminateProcessTree: (@Sendable (pid_t) -> Bool)? = nil
) async throws -> ProcessToolResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", request.command]

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
    let completion = ProcessToolCompletion()

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        stdout.append(handle.availableData)
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        stderr.append(handle.availableData)
    }

    return try await withCheckedThrowingContinuation { continuation in
        @Sendable func finishAfterClaim(
            timedOut: Bool,
            drainPipes: Bool = true,
            processCleanupConfirmed: Bool? = nil
        ) {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if drainPipes {
                stdout.append(stdoutPipe.fileHandleForReading.availableData)
                stderr.append(stderrPipe.fileHandleForReading.availableData)
            } else {
                try? stdoutPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForReading.close()
            }
            let standardOutput = stdout.snapshot()
            let standardError = stderr.snapshot()
            continuation.resume(returning: ProcessToolResult(
                command: request.command,
                workingDirectory: request.workingDirectory,
                exitCode: timedOut ? nil : process.terminationStatus,
                timedOut: timedOut,
                stdout: standardOutput.string,
                stderr: standardError.string,
                stdoutTruncated: standardOutput.truncated,
                stderrTruncated: standardError.truncated,
                processCleanupConfirmed: processCleanupConfirmed
            ))
        }

        do {
            try process.run()
        } catch {
            _ = completion.claim()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            continuation.resume(throwing: ProcessToolError.launchFailed(error.localizedDescription))
            return
        }

        let launchedIdentity: ProcessToolProcessIdentity
        switch processToolIdentity(for: process.processIdentifier) {
        case .found(let identity):
            launchedIdentity = identity
        case .missing, .unavailable:
            guard completion.claim() else { return }
            if process.isRunning {
                process.terminate()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: ProcessToolError.launchFailed("Could not capture launched process identity"))
            } else {
                finishAfterClaim(timedOut: false)
            }
            return
        }

        process.terminationHandler = { _ in
            guard completion.claim() else { return }
            finishAfterClaim(timedOut: false)
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + request.timeoutSeconds) {
            switch completion.claimTimeout(isRunning: { process.isRunning }) {
            case .unclaimed:
                return
            case .processExited:
                process.terminationHandler = nil
                finishAfterClaim(timedOut: false)
                return
            case .timedOut:
                process.terminationHandler = nil
            }
            let terminated = terminateProcessTree?(process.processIdentifier)
                ?? terminateProcessToolGroup(rootedAt: launchedIdentity)
            finishAfterClaim(
                timedOut: true,
                drainPipes: terminated,
                processCleanupConfirmed: terminated
            )
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
