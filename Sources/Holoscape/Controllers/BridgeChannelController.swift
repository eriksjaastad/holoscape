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
    let instanceNumber: Int?
    private(set) var customDisplayLabel: String?

    private(set) var activatedAt: Date? = Date()
    private(set) var lastInteractionAt: Date = Date()

    var displayLabel: String {
        if let customDisplayLabel {
            return customDisplayLabel
        }
        if let num = instanceNumber {
            return "Bridge \(num)"
        }
        return "Bridge"
    }

    func setCustomDisplayLabel(_ label: String?) {
        customDisplayLabel = ChannelCustomDisplayLabel.normalized(label)
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
        submitInput(text) { _ in }
    }

    func submitInput(_ text: String, completion: @escaping @MainActor (Bool) -> Void) {
        guard !text.isEmpty else {
            completion(false)
            return
        }
        let agents = channelManager.agentChannels()
        if agents.isEmpty {
            appendMessage("[System] No active agent channels to broadcast to.")
            completion(false)
            return
        }
        var remaining = agents.count
        var succeeded = 0
        for agent in agents {
            agent.submitInput(text) { [weak self] didSubmit in
                guard let self else {
                    completion(false)
                    return
                }
                if didSubmit { succeeded += 1 }
                remaining -= 1
                guard remaining == 0 else { return }
                guard succeeded > 0 else {
                    self.appendMessage("[System] Broadcast failed for every active agent channel.")
                    completion(false)
                    return
                }
                self.recordUserInteraction()
                self.commandHistory.add(text)
                let timeString = self.formatTime(Date())
                self.appendMessage("[\(timeString)] \u{2192} broadcast: \(text)")
                if succeeded < agents.count {
                    self.appendMessage("[System] Broadcast reached \(succeeded) of \(agents.count) active agent channels.")
                }
                completion(true)
            }
        }
    }

    func activate() {
        state = .active
        let now = Date()
        activatedAt = now
        recordUserInteraction(at: now)
        delegate?.channelStateDidChange(self, to: .active)
    }

    func recordUserInteraction(at date: Date = Date()) {
        lastInteractionAt = date
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
