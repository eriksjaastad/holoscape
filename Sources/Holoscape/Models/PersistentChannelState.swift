import Foundation

/// Durable, UI-facing channel state for tabs/sidebar rows.
///
/// This model is separate from the legacy runtime `ChannelState` so Holoscape
/// can keep process lifecycle plumbing stable while the UI grows richer state
/// truth for agents, shells, SSH, MCP, and plugin-backed channels.
struct PersistentChannelState: Codable, Equatable, Sendable {
    let kind: PersistentChannelStateKind
    let source: PersistentChannelStateSource
    let updatedAt: Date
    let reason: String?
    let recoveryAction: ChannelRecoveryAction?

    init(
        kind: PersistentChannelStateKind,
        source: PersistentChannelStateSource,
        updatedAt: Date = Date(),
        reason: String? = nil,
        recoveryAction: ChannelRecoveryAction? = nil
    ) {
        self.kind = kind
        self.source = source
        self.updatedAt = updatedAt
        self.reason = reason
        self.recoveryAction = recoveryAction
    }

    static func fromRuntimeState(
        _ state: ChannelState,
        source: PersistentChannelStateSource = .processLifecycle,
        updatedAt: Date = Date(),
        reason: String? = nil,
        recoveryAction: ChannelRecoveryAction? = nil
    ) -> PersistentChannelState {
        PersistentChannelState(
            kind: PersistentChannelStateKind(runtimeState: state),
            source: source,
            updatedAt: updatedAt,
            reason: reason,
            recoveryAction: recoveryAction
        )
    }
}

enum PersistentChannelStateKind: String, Codable, CaseIterable, Sendable {
    /// A shell/agent/process exists but has no known in-flight work.
    case ready
    /// The channel is actively producing output or an adapter marks it busy.
    case running
    /// The channel is blocked on an operator decision/approval prompt.
    case needsApproval = "needs-approval"
    /// The channel hit a terminal/process/adapter/plugin failure.
    case error
    /// The saved channel points at a missing or unverifiable external session.
    case stale

    init(runtimeState: ChannelState) {
        switch runtimeState {
        case .active:
            self = .running
        case .connecting:
            self = .running
        case .disconnected:
            self = .ready
        case .stale:
            self = .stale
        }
    }

    var requiresOperatorAttention: Bool {
        switch self {
        case .needsApproval, .error, .stale:
            return true
        case .ready, .running:
            return false
        }
    }

    var isRecoverable: Bool {
        switch self {
        case .error, .stale:
            return true
        case .ready, .running, .needsApproval:
            return false
        }
    }

    /// Stable priority for tab/sidebar rendering when multiple signals arrive.
    /// Higher wins so transient output cannot hide approval/error/stale states.
    var displayPriority: Int {
        switch self {
        case .ready: return 10
        case .running: return 20
        case .needsApproval: return 30
        case .error: return 40
        case .stale: return 50
        }
    }

    var displayLabel: String {
        switch self {
        case .ready: return "ready"
        case .running: return "running"
        case .needsApproval: return "needs approval"
        case .error: return "error"
        case .stale: return "stale"
        }
    }
}

enum PersistentChannelStateSource: String, Codable, CaseIterable, Sendable {
    case processLifecycle = "process-lifecycle"
    case terminalOutput = "terminal-output"
    case agentAdapter = "agent-adapter"
    case brokerRegistry = "broker-registry"
    case userAction = "user-action"
    case plugin
}

enum PersistentChannelStateClearingRule: String, Codable, CaseIterable, Sendable {
    case processExit = "process-exit"
    case nextPrompt = "next-prompt"
    case userInput = "user-input"
    case adapterUpdate = "adapter-update"
    case explicitRecovery = "explicit-recovery"
    case pluginUpdate = "plugin-update"
}
