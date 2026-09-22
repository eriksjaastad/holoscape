import AppKit
import Foundation

@MainActor
protocol ChannelController: AnyObject {
    var channelId: UUID { get }
    var channelType: ChannelType { get }
    var displayBaseLabel: String { get }
    var displayLabel: String { get }
    var hasUnread: Bool { get set }
    var state: ChannelState { get }
    var persistentState: PersistentChannelState { get }
    var contentView: NSView { get }
    var recoveryAction: ChannelRecoveryAction? { get }

    func sendInput(_ text: String)
    func activate()
    func deactivate()
    func retry()
    func lastLines(_ count: Int) -> [String]
    func applyPersistentState(_ state: PersistentChannelState)

    var commandHistory: CommandHistory { get }
    var delegate: ChannelControllerDelegate? { get set }
    var activatedAt: Date? { get }
}

extension ChannelController {
    var displayBaseLabel: String { displayLabel }

    var activatedAt: Date? { nil }
    var persistentState: PersistentChannelState {
        PersistentChannelState.fromRuntimeState(state, recoveryAction: recoveryAction)
    }
    var recoveryAction: ChannelRecoveryAction? {
        state == .disconnected ? .reconnect : nil
    }

    func applyPersistentState(_ state: PersistentChannelState) {}
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
