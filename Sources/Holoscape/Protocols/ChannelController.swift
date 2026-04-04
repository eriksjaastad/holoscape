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

    func sendInput(_ text: String)
    func activate()
    func deactivate()
    func retry()
    func lastLines(_ count: Int) -> [String]

    var commandHistory: CommandHistory { get }
    var delegate: ChannelControllerDelegate? { get set }
}
