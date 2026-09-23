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

    /// Ordinal consumed by `ReactiveUniformSnapshot.agentState` and the
    /// Holoscape shader/chrome contract in `docs/skins/05-reactive-uniforms.md`:
    /// 0=idle, 1=thinking/running, 2=tool-use/operator-wait, 3=error.
    ///
    /// This keeps MercuryDeck/state-variant skins tied to the durable tab truth
    /// model instead of one-off notification strings.
    var reactiveAgentStateOrdinal: Int32 {
        switch self {
        case .ready:
            return 0
        case .running:
            return 1
        case .needsApproval:
            return 2
        case .error, .stale:
            return 3
        }
    }

    /// Ordinal consumed by sidebar/tab state variants:
    /// 0=connected/usable, 1=attention-needed, 2=error/disconnected, 3=stale.
    var reactiveChannelConnectionOrdinal: Int32 {
        switch self {
        case .ready, .running:
            return 0
        case .needsApproval:
            return 1
        case .error:
            return 2
        case .stale:
            return 3
        }
    }

    /// Notification ordinal used by chrome state variants:
    /// 0=none, 1=info, 2=warn, 3=error.
    var reactiveNotificationKindOrdinal: Int32 {
        switch self {
        case .ready, .running:
            return 0
        case .needsApproval:
            return 2
        case .error, .stale:
            return 3
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
