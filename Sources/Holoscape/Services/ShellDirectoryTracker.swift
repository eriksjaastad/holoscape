import Foundation

/// Tracks simple local-shell directory changes from user input. This is
/// deliberately a fallback for terminal embeddings that do not reliably
/// receive OSC 7 current-directory notifications from zsh.
struct ShellDirectoryTracker {
    private(set) var currentDirectory: String?
    private var previousDirectory: String?
    private var pendingBytes: [UInt8] = []

    init(currentDirectory: String?) {
        self.currentDirectory = currentDirectory.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
    }

    mutating func consume(data: ArraySlice<UInt8>) -> String? {
        var latestDirectory: String?
        for byte in data {
            switch byte {
            case 10, 13:
                if let next = submitPendingCommand() {
                    latestDirectory = next
                }
            case 3, 21:
                pendingBytes.removeAll()
            case 8, 127:
                if !pendingBytes.isEmpty {
                    pendingBytes.removeLast()
                }
            case 27:
                // Cursor keys and terminal control sequences make the
                // command-line edit state ambiguous. Drop the speculative
                // buffer and let OSC 7, if present, be authoritative.
                pendingBytes.removeAll()
            default:
                if byte >= 32 {
                    pendingBytes.append(byte)
                }
            }
        }
        return latestDirectory
    }

    mutating func applyHostDirectoryUpdate(_ directory: String?) -> String? {
        guard let directory else { return nil }
        let rawPath: String
        if let url = URL(string: directory), url.scheme == "file" {
            rawPath = url.path
        } else {
            rawPath = directory
        }
        guard let standardized = standardizedDirectory(path: rawPath) else { return nil }
        return setCurrentDirectory(standardized)
    }

    mutating func resolveSubmittedCommand(_ command: String) -> String? {
        guard let target = cdTarget(from: command) else { return nil }
        let nextDirectory: String?
        if target == "-" {
            nextDirectory = previousDirectory.flatMap(standardizedDirectory(path:))
        } else {
            nextDirectory = resolvedDirectory(for: target)
        }
        guard let nextDirectory else { return nil }
        return setCurrentDirectory(nextDirectory)
    }

    private mutating func submitPendingCommand() -> String? {
        defer { pendingBytes.removeAll() }
        guard !pendingBytes.isEmpty,
              let command = String(data: Data(pendingBytes), encoding: .utf8) else {
            return nil
        }
        return resolveSubmittedCommand(command)
    }

    private mutating func setCurrentDirectory(_ nextDirectory: String) -> String? {
        guard nextDirectory != currentDirectory else { return nil }
        previousDirectory = currentDirectory
        currentDirectory = nextDirectory
        return nextDirectory
    }

    private func cdTarget(from command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(";"),
              !trimmed.contains("&&"),
              !trimmed.contains("||"),
              !trimmed.contains("|") else {
            return nil
        }

        let words = shellWords(trimmed)
        guard words.first == "cd" else { return nil }
        if words.count == 1 {
            return NSHomeDirectory()
        }

        let targetIndex = words.count > 1 && words[1] == "--" ? 2 : 1
        guard words.indices.contains(targetIndex), words.count == targetIndex + 1 else {
            return nil
        }
        return words[targetIndex].isEmpty ? NSHomeDirectory() : words[targetIndex]
    }

    private func resolvedDirectory(for rawPath: String) -> String? {
        let expandedPath = (rawPath as NSString).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return standardizedDirectory(path: expandedPath)
        }
        let base = currentDirectory ?? FileManager.default.currentDirectoryPath
        return standardizedDirectory(path: URL(fileURLWithPath: base).appendingPathComponent(expandedPath).path)
    }

    private func standardizedDirectory(path: String) -> String? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return standardized
    }

    private func shellWords(_ command: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var isEscaped = false

        for character in command {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    words.append(current)
                    current.removeAll()
                }
                continue
            }
            current.append(character)
        }

        if isEscaped {
            current.append("\\")
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words
    }
}
