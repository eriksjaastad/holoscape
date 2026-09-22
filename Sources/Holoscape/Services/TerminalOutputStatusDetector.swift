import Foundation

/// Detects durable agent/channel state from visible terminal scrollback.
///
/// This intentionally stays small and conservative: it recognizes the
/// Claude Code approval menus Erik actually needs highlighted, but avoids
/// classifying arbitrary numbered lists as operator-blocking prompts.
struct TerminalOutputStatusDetector {
    static func persistentState(fromLastLines lines: [String], now: Date = Date()) -> PersistentChannelState? {
        guard containsClaudeApprovalPrompt(lines) else { return nil }
        return PersistentChannelState(
            kind: .needsApproval,
            source: .terminalOutput,
            updatedAt: now,
            reason: "Claude Code awaiting approval"
        )
    }

    static func containsClaudeApprovalPrompt(_ lines: [String]) -> Bool {
        let visible = lines
            .suffix(40)
            .joined(separator: "\n")
            .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        guard visible.contains("1.") || visible.contains("1)") else { return false }
        guard visible.contains("yes") && visible.contains("no") else { return false }

        let normalized = visible
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")

        let hasApprovalQuestion = [
            "do you want to proceed",
            "do you want to allow",
            "allow this command",
            "allow this action",
            "approve",
            "permission",
            "requires your approval",
            "waiting for approval"
        ].contains { normalized.contains($0) }

        let hasClaudeChoiceShape =
            (normalized.contains("1. yes") || normalized.contains("1) yes")) &&
            (normalized.contains("2. yes") || normalized.contains("2) yes") || normalized.contains("yes, and") || normalized.contains("yes and")) &&
            (normalized.contains("3. no") || normalized.contains("3) no"))

        return hasApprovalQuestion && hasClaudeChoiceShape
    }
}
