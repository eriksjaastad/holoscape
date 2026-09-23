import Foundation

/// Detects durable agent/channel state from visible terminal scrollback.
///
/// This intentionally stays small and conservative: it recognizes the
/// Claude Code and Codex approval menus Erik actually needs highlighted, but
/// avoids classifying arbitrary numbered lists as operator-blocking prompts.
struct TerminalOutputStatusDetector {
    static func persistentState(fromLastLines lines: [String], now: Date = Date()) -> PersistentChannelState? {
        if containsClaudeApprovalPrompt(lines) {
            return PersistentChannelState(
                kind: .needsApproval,
                source: .terminalOutput,
                updatedAt: now,
                reason: "Claude Code awaiting approval"
            )
        }

        if containsCodexApprovalPrompt(lines) {
            return PersistentChannelState(
                kind: .needsApproval,
                source: .terminalOutput,
                updatedAt: now,
                reason: "Codex awaiting approval"
            )
        }

        return nil
    }

    static func containsClaudeApprovalPrompt(_ lines: [String]) -> Bool {
        let normalized = normalizedVisibleOutput(lines)
        guard hasNumberedYesNoChoices(normalized) else { return false }

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

        return hasApprovalQuestion
    }

    static func containsCodexApprovalPrompt(_ lines: [String]) -> Bool {
        let normalized = normalizedVisibleOutput(lines)
        guard hasNumberedYesNoChoices(normalized) else { return false }

        let mentionsCodex = normalized.contains("codex")
        let hasCodexApprovalQuestion = [
            "allow command",
            "allow this command",
            "allow this action",
            "approve command",
            "requires approval",
            "awaiting approval"
        ].contains { normalized.contains($0) }

        return mentionsCodex && hasCodexApprovalQuestion
    }

    private static func normalizedVisibleOutput(_ lines: [String]) -> String {
        lines
            .suffix(40)
            .joined(separator: "\n")
            .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
    }

    private static func hasNumberedYesNoChoices(_ normalized: String) -> Bool {
        guard normalized.contains("1.") || normalized.contains("1)") else { return false }
        guard normalized.contains("yes") && normalized.contains("no") else { return false }

        return (normalized.contains("1. yes") || normalized.contains("1) yes")) &&
            (normalized.contains("2. yes") || normalized.contains("2) yes") || normalized.contains("yes, and") || normalized.contains("yes and")) &&
            (normalized.contains("3. no") || normalized.contains("3) no"))
    }
}
