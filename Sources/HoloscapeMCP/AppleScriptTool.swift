import Foundation
import MCP

struct AppleScriptToolResult: Sendable, Equatable {
    let source: String
    let output: String
}

enum AppleScriptToolError: LocalizedError, Equatable {
    case missingSource
    case compileFailed(String)
    case executionFailed(number: Int?, message: String)

    var errorDescription: String? {
        switch self {
        case .missingSource:
            return "Missing 'source' parameter"
        case .compileFailed(let message):
            return "AppleScript compile failed: \(message)"
        case .executionFailed(let number, let message):
            if let number {
                return "AppleScript execution failed (\(number)): \(message)"
            }
            return "AppleScript execution failed: \(message)"
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

func runAppleScriptTool(args: [String: Value]) throws -> AppleScriptToolResult {
    let source = try appleScriptSource(from: args)
    guard let script = NSAppleScript(source: source) else {
        throw AppleScriptToolError.compileFailed("NSAppleScript could not initialize the script source")
    }

    var errorInfo: NSDictionary?
    let descriptor = script.executeAndReturnError(&errorInfo)
    if let errorInfo {
        throw AppleScriptToolError.executionFailed(
            number: errorInfo[NSAppleScript.errorNumber] as? Int,
            message: (errorInfo[NSAppleScript.errorMessage] as? String) ?? String(describing: errorInfo)
        )
    }

    return AppleScriptToolResult(
        source: source,
        output: appleScriptDescriptorString(descriptor)
    )
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
    "result:\n\(result.output.isEmpty ? "(empty)" : result.output)"
}
