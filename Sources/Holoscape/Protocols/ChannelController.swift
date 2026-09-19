import AppKit
import Foundation

@MainActor
protocol ChannelController: AnyObject {
    var channelId: UUID { get }
    var channelType: ChannelType { get }
    var displayLabel: String { get }
    var hasUnread: Bool { get set }
    var state: ChannelState { get }
    var contentView: NSView { get }
    var recoveryAction: ChannelRecoveryAction? { get }

    func sendInput(_ text: String)
    func activate()
    func deactivate()
    func retry()
    func lastLines(_ count: Int) -> [String]

    var commandHistory: CommandHistory { get }
    var delegate: ChannelControllerDelegate? { get set }
    var activatedAt: Date? { get }
}

extension ChannelController {
    var activatedAt: Date? { nil }
    var recoveryAction: ChannelRecoveryAction? {
        state == .disconnected ? .reconnect : nil
    }
}

enum ChannelRecoveryAction: Equatable, Sendable {
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
}
