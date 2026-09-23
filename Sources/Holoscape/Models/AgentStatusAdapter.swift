import Foundation

/// Maps external agent-tool lifecycle events into Holoscape's durable channel
/// state model. This keeps Claude hooks, Codex/OpenClaw-style status events,
/// and future agent CLIs behind the same product-facing contract.
struct AgentStatusAdapter: Sendable {
    enum Tool: String, Codable, CaseIterable, Sendable {
        case claude
        case codex
        case openClaw = "openclaw"
        case generic

        init(rawTool: String?) {
            guard let rawTool else {
                self = .generic
                return
            }
            switch rawTool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "claude", "claude-code", "claude_code":
                self = .claude
            case "codex", "codex-cli", "codex_cli":
                self = .codex
            case "openclaw", "open-claw", "open_claw":
                self = .openClaw
            default:
                self = .generic
            }
        }
    }

    enum Event: String, Codable, CaseIterable, Sendable {
        case running
        case ready
        case needsApproval = "needs-approval"
        case error
        case stale

        init?(rawEvent: String) {
            switch rawEvent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "running", "busy", "started", "response_started", "task_started":
                self = .running
            case "ready", "idle", "idle_prompt", "response_completed", "turn_complete", "task_complete":
                self = .ready
            case "needs-approval", "needs_approval", "permission_prompt", "approval_prompt", "user_decision", "awaiting_approval":
                self = .needsApproval
            case "error", "failed", "failure", "exception":
                self = .error
            case "stale", "detached", "session_stale", "session-missing", "session_missing":
                self = .stale
            default:
                return nil
            }
        }
    }

    func persistentState(
        tool rawTool: String?,
        event rawEvent: String,
        reason: String? = nil,
        updatedAt: Date = Date()
    ) -> PersistentChannelState? {
        guard let event = Event(rawEvent: rawEvent) else { return nil }
        let tool = Tool(rawTool: rawTool)
        let recoveryAction: ChannelRecoveryAction? = event == .stale ? .recreateBrokerSession : nil
        return PersistentChannelState(
            kind: event.stateKind,
            source: .agentAdapter,
            updatedAt: updatedAt,
            reason: reason ?? "\(tool.rawValue):\(event.rawValue)",
            recoveryAction: recoveryAction
        )
    }
}

private extension AgentStatusAdapter.Event {
    var stateKind: PersistentChannelStateKind {
        switch self {
        case .running:
            return .running
        case .ready:
            return .ready
        case .needsApproval:
            return .needsApproval
        case .error:
            return .error
        case .stale:
            return .stale
        }
    }
}
