import AppKit
import Foundation

@MainActor
class GroupChatChannelController: NSObject, ChannelController {
    let channelId: UUID
    let channelType: ChannelType = .groupChat
    var hasUnread: Bool = false
    private(set) var state: ChannelState = .disconnected
    let commandHistory = CommandHistory()
    weak var delegate: ChannelControllerDelegate?

    private let textView: NSTextView
    private let scrollView: NSScrollView
    let apiURL: String
    let apiKey: String
    let apiKeyEnv: String?
    private let sender: String = "erik"
    private var lastTimestamp: String?
    private var pollTimer: Timer?
    private var reconnectDelay: TimeInterval = 1.0
    private let maxReconnectDelay: TimeInterval = 30.0
    private let profileLabel: String
    private let instanceNumber: Int?

    private(set) var activatedAt: Date?

    var displayLabel: String {
        if let num = instanceNumber {
            return "\(profileLabel) \(num)"
        }
        return profileLabel
    }

    var contentView: NSView { scrollView }

    /// V2 initializer: constructed from SessionProfile fields.
    init(id: UUID, apiURL: String, apiKey: String, label: String, instanceNumber: Int?, apiKeyEnv: String? = nil) {
        self.channelId = id
        self.apiURL = apiURL.hasSuffix("/") ? String(apiURL.dropLast()) : apiURL
        self.apiKey = apiKey
        self.apiKeyEnv = apiKeyEnv
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

    /// V1 convenience initializer (backward compat).
    convenience init(id: UUID, apiURL: String, apiKey: String) {
        self.init(id: id, apiURL: apiURL, apiKey: apiKey, label: "Chat", instanceNumber: nil)
    }

    func sendInput(_ text: String) {
        guard !text.isEmpty else { return }
        commandHistory.add(text)

        let payload: [String: Any] = [
            "sender": sender,
            "body": text,
            "priority": "normal",
        ]

        guard let url = URL(string: "\(apiURL)/send"),
              let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = jsonData

        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error {
                Task { @MainActor [weak self] in
                    self?.appendMessage("[Error] Failed to send: \(error.localizedDescription)")
                }
            }
        }.resume()
    }

    func activate() {
        state = .connecting
        delegate?.channelStateDidChange(self, to: .connecting)
        reconnectDelay = 1.0
        activatedAt = nil
        startPolling()
    }

    func deactivate() {
        pollTimer?.invalidate()
        pollTimer = nil
        state = .disconnected
        activatedAt = nil
        delegate?.channelStateDidChange(self, to: .disconnected)
    }

    func retry() {
        activate()
    }

    func lastLines(_ count: Int) -> [String] {
        let content = textView.string
        let lines = content.components(separatedBy: "\n")
        return Array(lines.suffix(count))
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer?.invalidate()
        fetchMessages()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fetchMessages()
            }
        }
    }

    private func fetchMessages() {
        var urlString = "\(apiURL)/messages?limit=50"
        if let since = lastTimestamp {
            let encoded = since.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? since
            urlString += "&since=\(encoded)"
        }

        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    if self.state != .disconnected {
                        self.handleConnectionError(error)
                    }
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else { return }

                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    self.appendMessage("[Error] Authentication failed. Check API key.")
                    self.pollTimer?.invalidate()
                    self.state = .disconnected
                    self.delegate?.channelStateDidChange(self, to: .disconnected)
                    return
                }

                guard httpResponse.statusCode == 200,
                      let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let messages = json["messages"] as? [[String: Any]] else {
                    return
                }

                if self.state != .active {
                    self.state = .active
                    self.activatedAt = Date()
                    self.delegate?.channelStateDidChange(self, to: .active)
                    self.reconnectDelay = 1.0
                }

                // Auto-scroll only if at bottom
                let isAtBottom = self.isScrolledToBottom()

                for msg in messages {
                    guard let msgSender = msg["sender"] as? String,
                          let body = msg["body"] as? String,
                          let ts = msg["ts"] as? String else { continue }

                    self.lastTimestamp = ts

                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let date = formatter.date(from: ts) ?? Date()

                    let timeFormatter = DateFormatter()
                    timeFormatter.dateFormat = "h:mm a"
                    let timeString = timeFormatter.string(from: date)

                    self.appendMessage("[\(timeString)] \(msgSender): \(body)", autoScroll: isAtBottom)

                    if self.hasUnread == false {
                        self.hasUnread = true
                        self.delegate?.channelDidReceiveOutput(self)
                    }
                }
            }
        }.resume()
    }

    private func handleConnectionError(_ error: Error) {
        appendMessage("[Error] Connection failed: \(error.localizedDescription). Reconnecting in \(Int(reconnectDelay))s...")
        state = .connecting
        delegate?.channelStateDidChange(self, to: .connecting)

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: reconnectDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startPolling()
            }
        }
        reconnectDelay = min(reconnectDelay * 2, maxReconnectDelay)
    }

    private func appendMessage(_ text: String, autoScroll: Bool = true) {
        let attributed = NSAttributedString(
            string: text + "\n",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.white,
            ]
        )
        textView.textStorage?.append(attributed)
        if autoScroll {
            textView.scrollToEndOfDocument(nil)
        }
    }

    private func isScrolledToBottom() -> Bool {
        let clipView = scrollView.contentView
        let documentHeight = textView.frame.height
        let clipHeight = clipView.bounds.height
        let scrollPosition = clipView.bounds.origin.y
        return scrollPosition + clipHeight >= documentHeight - 20
    }
}
