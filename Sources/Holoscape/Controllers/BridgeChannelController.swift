import AppKit

@MainActor
class BridgeChannelController: NSObject, ChannelController {
    let channelId: UUID
    let channelType: ChannelType = .bridge
    var hasUnread: Bool = false
    private(set) var state: ChannelState = .active
    let commandHistory = CommandHistory()
    weak var delegate: ChannelControllerDelegate?

    private let textView: NSTextView
    private let scrollView: NSScrollView
    private let channelManager: ChannelManager
    private let instanceNumber: Int?

    private(set) var activatedAt: Date? = Date()

    var displayLabel: String {
        if let num = instanceNumber {
            return "Bridge \(num)"
        }
        return "Bridge"
    }

    var contentView: NSView { scrollView }

    init(id: UUID, channelManager: ChannelManager, instanceNumber: Int?) {
        self.channelId = id
        self.channelManager = channelManager
        self.instanceNumber = instanceNumber

        self.scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.textView = NSTextView(frame: scrollView.contentView.bounds)

        super.init()

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0)
        textView.textColor = NSColor.white
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        appendMessage("[System] Bridge channel ready. Messages will be broadcast to all active agent channels.")
    }

    func sendInput(_ text: String) {
        guard !text.isEmpty else { return }
        commandHistory.add(text)

        let agents = channelManager.agentChannels()
        if agents.isEmpty {
            appendMessage("[System] No active agent channels to broadcast to.")
            return
        }

        let timeString = formatTime(Date())
        appendMessage("[\(timeString)] \u{2192} broadcast: \(text)")

        for agent in agents {
            agent.sendInput(text)
        }
    }

    func activate() {
        state = .active
        activatedAt = Date()
        delegate?.channelStateDidChange(self, to: .active)
    }

    func deactivate() {
        state = .disconnected
        activatedAt = nil
        delegate?.channelStateDidChange(self, to: .disconnected)
    }

    func retry() { activate() }

    func lastLines(_ count: Int) -> [String] {
        let content = textView.string
        let lines = content.components(separatedBy: "\n")
        return Array(lines.suffix(count))
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private func formatTime(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    private func appendMessage(_ text: String) {
        let attributed = NSAttributedString(
            string: text + "\n",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.white,
            ]
        )
        textView.textStorage?.append(attributed)
        textView.scrollToEndOfDocument(nil)
    }
}
