import AppKit

@MainActor
class MCPChannelController: NSObject, ChannelController {
    let channelId: UUID
    let channelType: ChannelType = .mcp
    var hasUnread: Bool = false
    private(set) var state: ChannelState = .disconnected
    let commandHistory = CommandHistory()
    weak var delegate: ChannelControllerDelegate?

    private let textView: NSTextView
    private let scrollView: NSScrollView
    private let mcpClient: MCPClient
    let profileLabel: String
    private let instanceNumber: Int?

    private(set) var activatedAt: Date?

    var displayLabel: String {
        if let num = instanceNumber {
            return "\(profileLabel) \(num)"
        }
        return profileLabel
    }

    var contentView: NSView { scrollView }

    /// The endpoint URL (for persistence).
    let endpoint: URL

    init(id: UUID, endpoint: URL, label: String, instanceNumber: Int?) {
        self.channelId = id
        self.endpoint = endpoint
        self.mcpClient = MCPClient(endpoint: endpoint)
        self.profileLabel = label
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
    }

    func activate() {
        state = .connecting
        delegate?.channelStateDidChange(self, to: .connecting)

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.mcpClient.initialize()
                self.state = .active
                self.activatedAt = Date()
                self.delegate?.channelStateDidChange(self, to: .active)
                self.appendMessage("[System] Connected to MCP endpoint.")
            } catch {
                self.state = .disconnected
                self.delegate?.channelStateDidChange(self, to: .disconnected)
                self.appendMessage("[Error] Connection failed: \(error.localizedDescription)")
            }
        }
    }

    func sendInput(_ text: String) {
        guard !text.isEmpty, state == .active else { return }
        commandHistory.add(text)

        let timeString = formatTime(Date())
        appendMessage("[\(timeString)] erik: \(text)")

        Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.mcpClient.sendMessage(text)
                let responseTime = self.formatTime(Date())
                self.appendMessage("[\(responseTime)] CEO: \(response)")
                self.delegate?.channelDidReceiveOutput(self)
            } catch {
                self.appendMessage("[Error] Failed to send: \(error.localizedDescription)")
            }
        }
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

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
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
