import AppKit
@testable import Holoscape

@MainActor
class MockChannelController: NSObject, ChannelController {
    let channelId: UUID
    let channelType: ChannelType
    var hasUnread: Bool = false
    private(set) var state: ChannelState
    let commandHistory = CommandHistory()
    weak var delegate: ChannelControllerDelegate?
    var displayLabel: String
    private let _contentView = NSView()

    var contentView: NSView { _contentView }

    var activateCallCount = 0
    var deactivateCallCount = 0
    var sentInputs: [String] = []

    init(
        id: UUID = UUID(),
        type: ChannelType = .shell,
        label: String = "Mock",
        state: ChannelState = .disconnected
    ) {
        self.channelId = id
        self.channelType = type
        self.displayLabel = label
        self.state = state
        super.init()
    }

    func sendInput(_ text: String) {
        sentInputs.append(text)
    }

    func activate() {
        activateCallCount += 1
        state = .active
        delegate?.channelStateDidChange(self, to: .active)
    }

    func deactivate() {
        deactivateCallCount += 1
        state = .disconnected
        delegate?.channelStateDidChange(self, to: .disconnected)
    }

    func retry() {
        activate()
    }

    func lastLines(_ count: Int) -> [String] {
        return []
    }
}
