import Foundation
import MCP

enum FileSystemToolError: LocalizedError {
    case missingPath
    case missingPattern
    case missingContent
    case notDirectory(String)
    case notText(String)

    var errorDescription: String? {
        switch self {
        case .missingPath:
            return "Missing 'path' parameter"
        case .missingPattern:
            return "Missing 'pattern' parameter"
        case .missingContent:
            return "Missing 'content' parameter"
        case .notDirectory(let path):
            return "Not a directory: \(path)"
        case .notText(let path):
            return "File is not valid UTF-8 text: \(path)"
        }
    }
}

func expandedFileSystemPath(_ rawPath: String) -> String {
    (rawPath as NSString).expandingTildeInPath
}

func requiredPath(from args: [String: Value]) throws -> String {
    guard let path = args["path"]?.stringValue, !path.isEmpty else {
        throw FileSystemToolError.missingPath
    }
    return expandedFileSystemPath(path)
}

func readFileTool(args: [String: Value]) throws -> String {
    let path = try requiredPath(from: args)
    let maxBytes = args["maxBytes"]?.intValue ?? 128_000
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let limited = data.prefix(max(0, min(maxBytes, data.count)))
    guard var text = String(data: limited, encoding: .utf8) else {
        throw FileSystemToolError.notText(path)
    }
    if limited.count < data.count {
        text += "\n… truncated at \(limited.count) of \(data.count) bytes"
    }
    return text.isEmpty ? "(empty file)" : text
}

func writeFileTool(args: [String: Value]) throws -> String {
    let path = try requiredPath(from: args)
    guard let content = args["content"]?.stringValue else {
        throw FileSystemToolError.missingContent
    }
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: url, options: .atomic)
    return "Wrote \(content.utf8.count) bytes to \(path)"
}

func listDirectoryTool(args: [String: Value]) throws -> String {
    let path = try requiredPath(from: args)
    let limit = args["limit"]?.intValue ?? 200
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw FileSystemToolError.notDirectory(path)
    }
    let urls = try FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: path),
        includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
    )
    let lines = try urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(limit).map { url in
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        let suffix = values.isDirectory == true ? "/" : ""
        let size = values.isDirectory == true ? "" : " \(values.fileSize ?? 0)b"
        return "\(url.lastPathComponent)\(suffix)\(size)"
    }
    return lines.isEmpty ? "(empty directory)" : lines.joined(separator: "\n")
}

func searchFilesTool(args: [String: Value]) throws -> String {
    let root = try requiredPath(from: args)
    guard let pattern = args["pattern"]?.stringValue, !pattern.isEmpty else {
        throw FileSystemToolError.missingPattern
    }
    let limit = args["limit"]?.intValue ?? 100
    let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    var matches: [String] = []
    let rootURL = URL(fileURLWithPath: root)
    guard let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
        throw FileSystemToolError.notDirectory(root)
    }
    for case let url as URL in enumerator {
        let name = url.lastPathComponent
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        if regex.firstMatch(in: name, range: range) != nil {
            matches.append(url.path)
            if matches.count >= limit { break }
        }
    }
    return matches.isEmpty ? "(no matching files)" : matches.joined(separator: "\n")
}

func searchContentTool(args: [String: Value]) throws -> String {
    let root = try requiredPath(from: args)
    guard let pattern = args["pattern"]?.stringValue, !pattern.isEmpty else {
        throw FileSystemToolError.missingPattern
    }
    let limit = args["limit"]?.intValue ?? 100
    let regex = try NSRegularExpression(pattern: pattern)
    let rootURL = URL(fileURLWithPath: root)
    var matches: [String] = []
    guard let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
        throw FileSystemToolError.notDirectory(root)
    }
    for case let url as URL in enumerator {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true,
              let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, lineSubstr) in lines.enumerated() {
            let line = String(lineSubstr)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if regex.firstMatch(in: line, range: range) != nil {
                matches.append("\(url.path):\(index + 1):\(line)")
                if matches.count >= limit { return matches.joined(separator: "\n") }
            }
        }
    }
    return matches.isEmpty ? "(no content matches)" : matches.joined(separator: "\n")
}
