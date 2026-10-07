import AppKit
import Foundation

@MainActor
protocol ChannelController: AnyObject {
    var channelId: UUID { get }
    var channelType: ChannelType { get }
    var displayBaseLabel: String { get }
    var displayLabel: String { get }
    var customDisplayLabel: String? { get }
    var instanceNumber: Int? { get }
    var hasUnread: Bool { get set }
    var state: ChannelState { get }
    var persistentState: PersistentChannelState { get }
    var contentView: NSView { get }
    var recoveryAction: ChannelRecoveryAction? { get }
    var tabIdentityIndicator: ChannelTabIdentityIndicator? { get }

    func sendInput(_ text: String)
    func activate()
    func deactivate()
    func deactivate(completion: @escaping @MainActor () -> Void)
    func deactivateForClose(completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void)
    func deactivateForAppTermination(completion: @escaping @MainActor () -> Void)
    /// Resume lifecycle cleanup for a persisted, presentation-hidden close.
    /// Implementations with asynchronous attach must not detach until attach has
    /// committed, and must never launch a replacement process.
    func resumeRestoredCloseCleanup(
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    )
    func retry()
    func lastLines(_ count: Int) -> [String]
    func applyPersistentState(_ state: PersistentChannelState)
    func setCustomDisplayLabel(_ label: String?)

    var commandHistory: CommandHistory { get }
    var delegate: ChannelControllerDelegate? { get set }
    var activatedAt: Date? { get }
    var lastInteractionAt: Date { get }

    func recordUserInteraction(at date: Date)
}

extension ChannelController {
    var displayBaseLabel: String { displayLabel }
    var instanceNumber: Int? { nil }

    var activatedAt: Date? { nil }
    var lastInteractionAt: Date { activatedAt ?? .distantPast }
    var persistentState: PersistentChannelState {
        PersistentChannelState.fromRuntimeState(state, recoveryAction: recoveryAction)
    }
    var tabIdentityIndicator: ChannelTabIdentityIndicator? { nil }
    var recoveryAction: ChannelRecoveryAction? {
        state == .disconnected ? .reconnect : nil
    }

    func applyPersistentState(_ state: PersistentChannelState) {}
    func recordUserInteraction(at date: Date) {}
    func deactivate(completion: @escaping @MainActor () -> Void) {
        deactivate()
        completion()
    }
    func deactivateForClose(completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void) {
        deactivate { completion(.completed) }
    }
    func deactivateForAppTermination(completion: @escaping @MainActor () -> Void) {
        deactivate(completion: completion)
    }
    func resumeRestoredCloseCleanup(
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    ) {
        deactivate { completion(.completed) }
    }
}

enum ChannelCustomDisplayLabel {
    static func normalized(_ label: String?) -> String? {
        guard let label else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ChannelRecoveryAction: Codable, Equatable, Sendable {
    case reconnect
    case retryBrokerHost
    case recreateBrokerSession

    var menuTitle: String {
        switch self {
        case .reconnect:
            return "Reconnect"
        case .retryBrokerHost:
            return "Retry Broker Host"
        case .recreateBrokerSession:
            return "Recreate Session"
        }
    }

    var surfaceStatusText: String {
        switch self {
        case .reconnect:
            return "reconnect"
        case .retryBrokerHost:
            return "retry broker"
        case .recreateBrokerSession:
            return "recreate session"
        }
    }

    var operatorGuidance: String {
        switch self {
        case .reconnect:
            return "Restart this channel from its saved launch metadata."
        case .retryBrokerHost:
            return "Broker host is unavailable. Restart Holoscape or the bundled broker host, then retry; Holoscape preserved the broker session ID and will not spawn a replacement while the host is missing."
        case .recreateBrokerSession:
            return "Broker session is stale or missing. Recreate starts a replacement process for this tab and persists the new broker session ID."
        }
    }
}
