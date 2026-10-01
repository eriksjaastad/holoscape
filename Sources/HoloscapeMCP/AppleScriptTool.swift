import Foundation
import MCP

struct AppleScriptToolResult: Sendable, Equatable {
    let source: String
    let output: String
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
}

enum AppleScriptToolError: LocalizedError, Equatable {
    case missingSource
    case invalidTimeout
    case compileFailed(String)
    case executionFailed(number: Int?, message: String)
    case executionOutputTruncated(exitCode: Int32, stdout: Bool, stderr: Bool)
    case timedOut(seconds: Double)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingSource:
            return "Missing 'source' parameter"
        case .invalidTimeout:
            return "timeoutSeconds must be greater than 0"
        case .compileFailed(let message):
            return "AppleScript compile failed: \(message)"
        case .executionFailed(let number, let message):
            if let number {
                return "AppleScript execution failed (\(number)): \(message)"
            }
            return "AppleScript execution failed: \(message)"
        case .executionOutputTruncated(let exitCode, let stdout, let stderr):
            return "AppleScript execution failed with exit code \(exitCode); output truncated (stdout: \(stdout), stderr: \(stderr))"
        case .timedOut(let seconds):
            return "AppleScript execution timed out after \(seconds) seconds"
        case .launchFailed(let reason):
            return "AppleScript launch failed: \(reason)"
        }
    }
}

func appleScriptSource(from args: [String: Value]) throws -> String {
    guard let source = args["source"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
          !source.isEmpty else {
        throw AppleScriptToolError.missingSource
    }
    return source
}

func appleScriptTimeout(from args: [String: Value]) throws -> Double {
    let timeout = args["timeoutSeconds"]?.doubleValue
        ?? args["timeoutSeconds"]?.intValue.map(Double.init)
        ?? 30
    guard timeout > 0 else {
        throw AppleScriptToolError.invalidTimeout
    }
    return timeout
}

func runAppleScriptTool(
    args: [String: Value],
    maxOutputBytes: Int = 1_048_576
) async throws -> AppleScriptToolResult {
    let source = try appleScriptSource(from: args)
    let timeout = try appleScriptTimeout(from: args)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]

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
        @Sendable func collectOutput() -> (
            stdout: (string: String, truncated: Bool),
            stderr: (string: String, truncated: Bool)
        )? {
            guard completion.claim() else { return nil }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            stdout.append(stdoutPipe.fileHandleForReading.availableData)
            stderr.append(stderrPipe.fileHandleForReading.availableData)
            return (stdout.snapshot(), stderr.snapshot())
        }

        process.terminationHandler = { process in
            guard let output = collectOutput() else { return }
            let standardOutput = output.stdout.string.trimmingCharacters(in: .newlines)
            let standardError = output.stderr.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                if output.stdout.truncated || output.stderr.truncated {
                    continuation.resume(throwing: AppleScriptToolError.executionOutputTruncated(
                        exitCode: process.terminationStatus,
                        stdout: output.stdout.truncated,
                        stderr: output.stderr.truncated
                    ))
                    return
                }
                continuation.resume(throwing: parseAppleScriptExecutionError(from: standardError))
                return
            }
            continuation.resume(returning: AppleScriptToolResult(
                source: source,
                output: standardOutput,
                stdoutTruncated: output.stdout.truncated,
                stderrTruncated: output.stderr.truncated
            ))
        }

        do {
            try process.run()
        } catch {
            guard collectOutput() != nil else { return }
            continuation.resume(throwing: AppleScriptToolError.launchFailed(error.localizedDescription))
            return
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            process.terminate()
            guard collectOutput() != nil else { return }
            continuation.resume(throwing: AppleScriptToolError.timedOut(seconds: timeout))
        }
    }
}

func parseAppleScriptExecutionError(from stderr: String) -> AppleScriptToolError {
    let message = stderr.isEmpty ? "osascript exited with a non-zero status" : stderr
    let pattern = #"execution error: (.*) \((-?\d+)\)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
          match.numberOfRanges == 3,
          let messageRange = Range(match.range(at: 1), in: message),
          let numberRange = Range(match.range(at: 2), in: message),
          let number = Int(message[numberRange]) else {
        return .executionFailed(number: nil, message: message)
    }
    return .executionFailed(number: number, message: String(message[messageRange]))
}

func appleScriptDescriptorString(_ descriptor: NSAppleEventDescriptor) -> String {
    if let stringValue = descriptor.stringValue {
        return stringValue
    }

    switch descriptor.descriptorType {
    case typeBoolean:
        return descriptor.booleanValue ? "true" : "false"
    case typeSInt16, typeSInt32, typeUInt32, typeSInt64:
        return String(descriptor.int32Value)
    case typeNull:
        return "(no result)"
    default:
        return descriptor.description
    }
}

func formatAppleScriptToolResult(_ result: AppleScriptToolResult) -> String {
    var lines: [String] = []
    if result.stdoutTruncated {
        lines.append("stdoutTruncated: true")
    }
    if result.stderrTruncated {
        lines.append("stderrTruncated: true")
    }
    lines.append("result:")
    lines.append(result.output.isEmpty ? "(empty)" : result.output)
    return lines.joined(separator: "\n")
}
