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

private struct ProcessToolProcessIdentity: Hashable, Sendable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    init?(pid: pid_t) {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize) == expectedSize else {
            return nil
        }
        self.pid = pid
        startSeconds = info.pbi_start_tvsec
        startMicroseconds = info.pbi_start_tvusec
    }

    var isAlive: Bool {
        guard let current = Self(pid: pid) else { return false }
        return current == self
    }
}

private func processToolDirectChildren(of parentPID: pid_t) -> [pid_t] {
    let estimatedBytes = max(Int(proc_listchildpids(parentPID, nil, 0)), 0)
    let estimatedCount = estimatedBytes / MemoryLayout<pid_t>.stride
    var capacity = max(estimatedCount + 16, 16)
    while true {
        var childPIDs = [pid_t](repeating: 0, count: capacity)
        let count = proc_listchildpids(
            parentPID,
            &childPIDs,
            Int32(childPIDs.count * MemoryLayout<pid_t>.stride)
        )
        guard count > 0 else { return [] }
        guard count >= capacity else { return Array(childPIDs.prefix(Int(count))) }
        capacity *= 2
    }
}

private func processToolDescendants(of rootPID: pid_t) -> Set<ProcessToolProcessIdentity> {
    var descendants: Set<ProcessToolProcessIdentity> = []
    var pending = processToolDirectChildren(of: rootPID)
    while let pid = pending.popLast() {
        guard let identity = ProcessToolProcessIdentity(pid: pid), descendants.insert(identity).inserted else {
            continue
        }
        pending.append(contentsOf: processToolDirectChildren(of: pid))
    }
    return descendants
}

private func terminateProcessToolTree(
    rootedAt rootPID: pid_t,
    gracePeriodMilliseconds: Int = 250
) -> Bool {
    guard let root = ProcessToolProcessIdentity(pid: rootPID) else { return true }
    var ownedProcesses = processToolDescendants(of: rootPID)
    ownedProcesses.insert(root)

    func signalAliveProcesses(_ signal: Int32) {
        for identity in ownedProcesses where identity.isAlive {
            _ = Darwin.kill(identity.pid, signal)
        }
    }

    signalAliveProcesses(SIGTERM)
    let termDeadline = DispatchTime.now() + .milliseconds(gracePeriodMilliseconds)
    while DispatchTime.now() < termDeadline {
        let discovered = ownedProcesses.reduce(into: Set<ProcessToolProcessIdentity>()) { result, identity in
            guard identity.isAlive else { return }
            result.formUnion(processToolDescendants(of: identity.pid))
        }.subtracting(ownedProcesses)
        if !discovered.isEmpty {
            ownedProcesses.formUnion(discovered)
            signalAliveProcesses(SIGTERM)
        }
        guard ownedProcesses.contains(where: \.isAlive) else { return true }
        usleep(10_000)
    }

    signalAliveProcesses(SIGKILL)
    let killDeadline = DispatchTime.now() + .milliseconds(gracePeriodMilliseconds)
    while DispatchTime.now() < killDeadline, ownedProcesses.contains(where: \.isAlive) {
        usleep(10_000)
    }
    return !ownedProcesses.contains(where: \.isAlive)
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
    maxOutputBytes: Int = 1_048_576
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
        @Sendable func finishAfterClaim(timedOut: Bool, drainPipes: Bool = true) {
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
                stderrTruncated: standardError.truncated
            ))
        }

        process.terminationHandler = { _ in
            guard completion.claim() else { return }
            finishAfterClaim(timedOut: false)
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

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + request.timeoutSeconds) {
            guard completion.claim() else { return }
            process.terminationHandler = nil
            let terminated = terminateProcessToolTree(rootedAt: process.processIdentifier)
            if !terminated {
                stderr.append(Data("Timed out; process cleanup could not be confirmed\n".utf8))
            }
            finishAfterClaim(timedOut: true, drainPipes: terminated)
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
    lines.append("stdout:")
    lines.append(result.stdout.isEmpty ? "(empty)" : result.stdout)
    lines.append("stderr:")
    lines.append(result.stderr.isEmpty ? "(empty)" : result.stderr)
    return lines.joined(separator: "\n")
}
