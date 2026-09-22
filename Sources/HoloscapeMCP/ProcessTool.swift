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

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        chunks.append(data)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let data = chunks.reduce(into: Data()) { partial, chunk in
            partial.append(chunk)
        }
        lock.unlock()
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
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

func runProcessTool(_ request: ProcessToolRequest) async throws -> ProcessToolResult {
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

    let stdout = ProcessToolOutputBuffer()
    let stderr = ProcessToolOutputBuffer()
    let completion = ProcessToolCompletion()

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        stdout.append(handle.availableData)
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        stderr.append(handle.availableData)
    }

    return try await withCheckedThrowingContinuation { continuation in
        @Sendable func finish(timedOut: Bool) {
            guard completion.claim() else { return }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdout.append(stdoutPipe.fileHandleForReading.availableData)
            stderr.append(stderrPipe.fileHandleForReading.availableData)
            continuation.resume(returning: ProcessToolResult(
                command: request.command,
                workingDirectory: request.workingDirectory,
                exitCode: timedOut ? nil : process.terminationStatus,
                timedOut: timedOut,
                stdout: stdout.string(),
                stderr: stderr.string()
            ))
        }

        process.terminationHandler = { _ in
            finish(timedOut: false)
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
            guard process.isRunning else { return }
            process.terminate()
            finish(timedOut: true)
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
    lines.append("stdout:")
    lines.append(result.stdout.isEmpty ? "(empty)" : result.stdout)
    lines.append("stderr:")
    lines.append(result.stderr.isEmpty ? "(empty)" : result.stderr)
    return lines.joined(separator: "\n")
}
