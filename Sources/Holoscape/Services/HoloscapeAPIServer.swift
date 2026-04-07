import Foundation
import Network
import UserNotifications

@MainActor
class HoloscapeAPIServer {
    private var listener: NWListener?
    private weak var channelManager: ChannelManager?
    private weak var windowController: MainWindowController?
    private let port: UInt16 = 7865

    /// Notification state per channel: "permission_prompt", "idle_prompt", or nil (normal)
    private(set) var channelNotifications: [UUID: String] = [:]

    init(channelManager: ChannelManager, windowController: MainWindowController) {
        self.channelManager = channelManager
        self.windowController = windowController
    }

    /// Suppress notifications for a grace period after launch (tabs start idle)
    private var suppressUntil: Date = Date().addingTimeInterval(10)

    func start() {
        let params = NWParameters.tcp
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            NSLog("HoloscapeAPI: Failed to create listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                NSLog("HoloscapeAPI: Listening on port \(nwPort)")
            case .failed(let error):
                NSLog("HoloscapeAPI: Listener failed: \(error)")
            default:
                break
            }
        }

        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private nonisolated func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let data, let request = HTTPParser.parse(data) else {
                let resp = HTTPResponse.error("Bad request")
                connection.send(content: resp.serialize(), completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
                return
            }

            Task { @MainActor [weak self] in
                guard let self else {
                    connection.cancel()
                    return
                }
                let response = await self.route(request)
                connection.send(content: response.serialize(), completion: .contentProcessed({ _ in
                    connection.cancel()
                }))
            }
        }
    }

    // MARK: - Router

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/channels"):
            return handleListChannels()

        case ("POST", "/channels"):
            return handleCreateChannel(request)

        case ("DELETE", let path) where path.hasPrefix("/channels/"):
            guard let id = request.pathComponent(after: "/channels/") else {
                return .error("Missing channel ID")
            }
            return handleCloseChannel(id: id)

        case ("POST", let path) where path.hasSuffix("/switch"):
            guard let id = request.pathComponent(after: "/channels/") else {
                return .error("Missing channel ID")
            }
            return handleSwitchChannel(id: id)

        case ("POST", let path) where path.hasSuffix("/input"):
            guard let id = request.pathComponent(after: "/channels/") else {
                return .error("Missing channel ID")
            }
            return handleSendInput(id: id, request: request)

        case ("GET", let path) where path.hasSuffix("/output"):
            guard let id = request.pathComponent(after: "/channels/") else {
                return .error("Missing channel ID")
            }
            let lines = Int(request.queryParams["lines"] ?? "50") ?? 50
            return handleReadOutput(id: id, lines: lines)

        case ("POST", "/notify"):
            return handleNotify(request)

        default:
            return .error("Not found", status: 404)
        }
    }

    // MARK: - Handlers

    private func handleListChannels() -> HTTPResponse {
        guard let cm = channelManager else { return .error("Not ready", status: 500) }
        let channels = cm.allChannels().map { channel -> [String: Any] in
            [
                "id": channel.channelId.uuidString,
                "label": channel.displayLabel,
                "type": channel.channelType.rawValue,
                "state": channel.state.rawValue
            ]
        }
        return .json(channels)
    }

    private func handleCreateChannel(_ request: HTTPRequest) -> HTTPResponse {
        guard let wc = windowController else { return .error("Not ready", status: 500) }
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .error("Invalid JSON body")
        }

        let type = json["type"] as? String ?? "shell"
        let dir = json["dir"] as? String
        let label = json["label"] as? String
        let cmd = json["cmd"] as? String

        wc.openChannel(type: type, directory: dir, label: label, command: cmd)
        return .json(["status": "created"], status: 201)
    }

    private func handleCloseChannel(id: String) -> HTTPResponse {
        guard let channel = resolveChannel(id: id) else {
            return .error("Channel not found", status: 404)
        }
        windowController?.closeChannel(id: channel.channelId)
        return .json(["status": "closed"])
    }

    private func handleSwitchChannel(id: String) -> HTTPResponse {
        guard let channel = resolveChannel(id: id) else {
            return .error("Channel not found", status: 404)
        }
        windowController?.switchToChannel(channel.channelId)
        return .json(["status": "switched", "label": channel.displayLabel])
    }

    private func handleSendInput(id: String, request: HTTPRequest) -> HTTPResponse {
        guard let channel = resolveChannel(id: id) else {
            return .error("Channel not found", status: 404)
        }
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = json["text"] as? String else {
            return .error("Missing 'text' in body")
        }
        channel.sendInput(text)
        return .json(["status": "sent"])
    }

    private func handleReadOutput(id: String, lines: Int) -> HTTPResponse {
        guard let channel = resolveChannel(id: id) else {
            return .error("Channel not found", status: 404)
        }
        let output = channel.lastLines(lines)
        return .json(["lines": output, "channel": channel.displayLabel])
    }

    private func handleNotify(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let type = json["type"] as? String else {
            return .error("Missing 'type' in body")
        }

        // Ignore notifications during startup grace period
        if Date() < suppressUntil {
            return .json(["status": "suppressed"])
        }

        let cwd = json["cwd"] as? String
        // Match notification to a channel by working directory
        if let cwd, let channel = resolveChannelByCwd(cwd: cwd) {
            channelNotifications[channel.channelId] = type
            // Trigger tab refresh to update colors
            windowController?.refreshAllTabs()

            // Send macOS notification for key events
            if type == "permission_prompt" || type == "idle_prompt" {
                sendDesktopNotification(type: type, channel: channel.displayLabel)
            }
        }

        return .json(["status": "received", "type": type])
    }

    private func resolveChannelByCwd(cwd: String) -> (any ChannelController)? {
        guard let cm = channelManager else { return nil }
        let cwdName = URL(fileURLWithPath: cwd).lastPathComponent
        // Match by directory name in display label
        return cm.allChannels().first { $0.displayLabel.lowercased() == cwdName.lowercased() }
    }

    private func sendDesktopNotification(type: String, channel: String) {
        let content = UNMutableNotificationContent()
        switch type {
        case "permission_prompt":
            content.title = "Permission Needed"
            content.body = "\(channel) is waiting for approval"
        case "idle_prompt":
            content.title = "Task Complete"
            content.body = "\(channel) is ready for input"
        default:
            content.title = "Holoscape"
            content.body = "\(channel): \(type)"
        }
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Clear notification state when switching to a channel
    func clearNotification(for channelId: UUID) {
        channelNotifications.removeValue(forKey: channelId)
    }

    // MARK: - Helpers

    private func resolveChannel(id: String) -> (any ChannelController)? {
        guard let cm = channelManager else { return nil }
        // Try UUID first
        if let uuid = UUID(uuidString: id) {
            return cm.channel(for: uuid)
        }
        // Fall back to label match
        return cm.allChannels().first { $0.displayLabel.lowercased() == id.lowercased() }
    }
}
