import Foundation

struct RoleDetector {
    /// Parse CLAUDE.md to extract role identifier.
    /// Looks for pattern: > **You are the {role}**
    static func detectRole(in directory: URL) -> String? {
        let claudeMdURL = directory.appendingPathComponent("CLAUDE.md")
        guard let content = try? String(contentsOf: claudeMdURL, encoding: .utf8) else {
            return nil
        }
        return detectRole(from: content)
    }

    /// Parse role from CLAUDE.md content string.
    static func detectRole(from content: String) -> String? {
        // Match: **You are the {role} of {project}.**
        // or:   **You are the {role}.**
        // or:   **You are the {role}**
        let pattern = #"\*\*[Yy]ou are the ([^.*]+?)(?:\s+of\s+[^.*]+)?\.*\*\*"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: content,
                range: NSRange(content.startIndex..., in: content)
              ),
              let roleRange = Range(match.range(at: 1), in: content) else {
            return nil
        }
        return String(content[roleRange]).trimmingCharacters(in: .whitespaces)
    }

    /// Convert a detected role string to a short tab label.
    /// "floor manager" -> "FM", "architect" -> "ARC", "ceo" -> "CEO"
    static func shortLabel(for role: String) -> String {
        let words = role.lowercased().split(separator: " ")
        if words.count == 1 {
            let word = String(words[0])
            return String(word.prefix(3)).uppercased()
        }
        return words.map { String($0.prefix(1)).uppercased() }.joined()
    }
}
