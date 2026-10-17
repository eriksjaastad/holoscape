import AppKit
import Foundation
import Network
import UserNotifications

protocol HTTPServerConnection: AnyObject, Sendable {
    func start(queue: DispatchQueue)
    func receive(completion: @escaping @Sendable (Data?, Bool, NWError?) -> Void)
    func send(content: Data, completion: @escaping @Sendable (NWError?) -> Void)
    func cancel()
}

private final class NetworkHTTPServerConnection: HTTPServerConnection {
    private let connection: NWConnection

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start(queue: DispatchQueue) {
        connection.start(queue: queue)
    }

    func receive(completion: @escaping @Sendable (Data?, Bool, NWError?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            completion(data, isComplete, error)
        }
    }

    func send(content: Data, completion: @escaping @Sendable (NWError?) -> Void) {
        connection.send(content: content, completion: .contentProcessed(completion))
    }

    func cancel() {
        connection.cancel()
    }
}

@MainActor
protocol DockAttentionClient: AnyObject {
    var badgeLabel: String? { get set }
    func requestUserAttention()
}

@MainActor
final class SystemDockAttentionClient: DockAttentionClient {
    var badgeLabel: String? {
        get { NSApp.dockTile.badgeLabel }
        set { NSApp.dockTile.badgeLabel = newValue }
    }

    func requestUserAttention() {
        NSApp.requestUserAttention(.informationalRequest)
    }
}

@MainActor
class HoloscapeAPIServer {
    nonisolated static let maximumRequestBytes = 1_048_576

    enum RequestReceiveDecision {
        case receiveMore(Data)
        case route(HTTPRequest)
        case respond(HTTPResponse)
    }

    private var listener: NWListener?
    private var acceptsRequests = false
    private weak var channelManager: ChannelManager?
    private weak var windowController: MainWindowController?
    let port: UInt16

    /// Notification state per channel: legacy Claude hook names or adapter-backed
    /// events such as Codex `awaiting_approval` / `response_completed`.
    private(set) var channelNotifications: [UUID: String] = [:]
    private(set) var mutedNotificationChannelIds: Set<UUID> = []
    private let agentStatusAdapter = AgentStatusAdapter()
    private let dockAttentionClient: DockAttentionClient

    init(
        channelManager: ChannelManager,
        windowController: MainWindowController,
        port: UInt16 = 7865,
        dockAttentionClient: DockAttentionClient = SystemDockAttentionClient()
    ) {
        self.channelManager = channelManager
        self.windowController = windowController
        self.port = port
        self.dockAttentionClient = dockAttentionClient
    }

    /// Suppress notifications for a grace period after launch (tabs start idle)
    private var suppressUntil: Date = {
        if ProcessInfo.processInfo.arguments.contains("--disable-notification-suppression") {
            return Date()
        }
        return Date().addingTimeInterval(10)
    }()

    nonisolated static func listenerParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        return parameters
    }

    func start() {
        let parameters = Self.listenerParameters()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            acceptsRequests = false
            NSLog("HoloscapeAPI: Failed to create listener: \(error)")
            return
        }
        acceptsRequests = true

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(NetworkHTTPServerConnection(connection))
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
        // Accepted connections can outlive the listener. Close admission before
        // cancellation so no queued mutation crosses the teardown snapshot.
        acceptsRequests = false
        listener?.cancel()
        listener = nil
    }

    nonisolated func handleConnection(_ connection: HTTPServerConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveFullRequest(connection: connection, accumulated: Data())
    }

    nonisolated static func requestReceiveDecision(
        accumulated: Data,
        incoming: Data,
        isComplete: Bool,
        maximumBytes: Int = maximumRequestBytes
    ) -> RequestReceiveDecision {
        guard maximumBytes >= 0,
              accumulated.count <= maximumBytes,
              incoming.count <= maximumBytes - accumulated.count else {
            return .respond(.error("Payload too large", status: 413))
        }
        var buffer = accumulated
        buffer.append(incoming)

        switch HTTPParser.parse(buffer, maximumRequestBytes: maximumBytes) {
        case .request(let request):
            return .route(request)
        case .payloadTooLarge:
            return .respond(.error("Payload too large", status: 413))
        case .badRequest:
            return .respond(.error("Bad request"))
        case .incomplete where isComplete:
            return .respond(.error("Bad request"))
        case .incomplete:
            return .receiveMore(buffer)
        }
    }

    /// Accumulate data until we have a complete HTTP request (headers + body).
    private nonisolated func receiveFullRequest(connection: HTTPServerConnection, accumulated: Data) {
        connection.receive { [weak self] data, isComplete, error in
            switch Self.requestReceiveDecision(
                accumulated: accumulated,
                incoming: data ?? Data(),
                isComplete: isComplete
            ) {
            case .route(let request):
                Task { @MainActor [weak self] in
                    guard let self else { connection.cancel(); return }
                    let response = await self.route(request)
                    Self.sendAndClose(response, connection: connection)
                }
            case .respond(let response):
                Self.sendAndClose(response, connection: connection)
            case .receiveMore(let buffer):
                if error == nil {
                    self?.receiveFullRequest(connection: connection, accumulated: buffer)
                } else {
                    connection.cancel()
                }
            }
        }
    }

    private nonisolated static func sendAndClose(
        _ response: HTTPResponse,
        connection: HTTPServerConnection
    ) {
        connection.send(content: response.serialize()) { error in
            if let error {
                NSLog("HoloscapeAPI: Failed to send response: \(error)")
            }
            connection.cancel()
        }
    }

    // MARK: - Router

    func route(_ request: HTTPRequest) async -> HTTPResponse {
        guard acceptsRequests else {
            return .error("Service unavailable", status: 503)
        }
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
        let activeId = windowController?.activeChannelId
        let channels = cm.allChannels().map { channel -> [String: Any] in
            [
                "id": channel.channelId.uuidString,
                "label": channel.displayLabel,
                "type": channel.channelType.rawValue,
                "state": channel.state.rawValue,
                "persistent_state": channel.persistentState.kind.rawValue,
                "persistent_state_source": channel.persistentState.source.rawValue,
                "notification_type": channelNotifications[channel.channelId] as Any,
                "notifications_muted": mutedNotificationChannelIds.contains(channel.channelId),
                "is_active": channel.channelId == activeId
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

        let type: String
        if let suppliedType = json["type"] {
            guard let suppliedType = suppliedType as? String else {
                return .error("Channel type must be a string", status: 400)
            }
            type = suppliedType
        } else {
            type = "shell"
        }
        let dir = json["dir"] as? String
        let label = json["label"] as? String
        let cmd = json["cmd"] as? String

        switch wc.openChannel(type: type, directory: dir, label: label, command: cmd) {
        case .created:
            return .json(["status": "created"], status: 201)
        case .mutationsDisabled:
            return .error("Channel creation is temporarily unavailable", status: 503)
        case .unsupportedType(let unsupportedType):
            return .error("Unsupported channel type: \(unsupportedType)", status: 400)
        }
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
        let tool = json["tool"] as? String ?? json["agent"] as? String
        let reason = json["reason"] as? String
        let ownerToken = json["ownerToken"] as? String
        // Match scoped events by launch ownership, not tab order. Tokenless
        // legacy events remain available only when cwd identifies one eligible
        // channel unambiguously.
        if let cwd, let channel = resolveNotificationChannelByCwd(cwd: cwd, ownerToken: ownerToken) {
            let persistentState = agentStatusAdapter.persistentState(
                tool: tool,
                event: type,
                reason: reason
            )
            channelNotifications[channel.channelId] = type
            if let persistentState {
                if let agentChannel = channel as? AgentChannelController {
                    agentChannel.applyPersistentState(
                        persistentState,
                        adapterOwnerToken: ownerToken
                    )
                } else {
                    channel.applyPersistentState(persistentState)
                }
            }
            // Trigger tab refresh to update colors
            windowController?.refreshAllTabs()

            // Send off-screen attention only for unmuted, inactive channels.
            if shouldRequestOffscreenAttention(for: channel, type: type, tool: tool) {
                requestOffscreenAttention(type: type, tool: tool, channel: channel)
            }
            return .json(["status": "received", "type": type])
        }

        return .json(["status": "ignored", "type": type])
    }

    private func resolveNotificationChannelByCwd(cwd: String, ownerToken: String?) -> (any ChannelController)? {
        guard let cm = channelManager else { return nil }
        return Self.resolveNotificationChannel(
            channels: cm.allChannels(),
            cwd: cwd,
            ownerToken: ownerToken
        )
    }

    static func resolveNotificationChannel(
        channels: [any ChannelController],
        cwd: String,
        ownerToken: String?
    ) -> (any ChannelController)? {
        let normalizedCwd = normalizePath(cwd)

        let exactMatches = channels.filter { channel in
            switch channel {
            case let shell as ShellChannelController:
                guard let path = shell.notificationDirectoryPath else { return false }
                return normalizePath(path) == normalizedCwd
            case let agent as AgentChannelController:
                guard let path = agent.notificationDirectoryPath else { return false }
                return normalizePath(path) == normalizedCwd
            default:
                return false
            }
        }

        let eligibleExactMatches = eligibleNotificationChannels(exactMatches, ownerToken: ownerToken)
        if eligibleExactMatches.count == 1 { return eligibleExactMatches[0] }
        if !eligibleExactMatches.isEmpty || !exactMatches.isEmpty { return nil }

        let cwdName = URL(fileURLWithPath: normalizedCwd).lastPathComponent.lowercased()
        // Fallback for older tests/callers that still encode the target in the label.
        let labelMatches = channels.filter { $0.displayLabel.lowercased() == cwdName }
        let eligibleLabelMatches = eligibleNotificationChannels(labelMatches, ownerToken: ownerToken)
        return eligibleLabelMatches.count == 1 ? eligibleLabelMatches[0] : nil
    }

    private static func eligibleNotificationChannels(
        _ channels: [any ChannelController],
        ownerToken: String?
    ) -> [any ChannelController] {
        if ownerToken != nil {
            return channels.compactMap { channel in
                guard let agent = channel as? AgentChannelController,
                      agent.acceptsAdapterEvent(ownerToken: ownerToken) else { return nil }
                return agent
            }
        }
        return channels.filter { channel in
            guard let agent = channel as? AgentChannelController else { return true }
            return agent.acceptsAdapterEvent(ownerToken: nil)
        }
    }

    private static func normalizePath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    static func offscreenAttentionKind(type: String, tool: String?) -> PersistentChannelStateKind? {
        guard let state = AgentStatusAdapter().persistentState(tool: tool, event: type) else {
            return nil
        }

        switch state.kind {
        case .needsApproval, .ready:
            return state.kind
        case .running, .error, .stale, .disconnected:
            return nil
        }
    }

    private func shouldRequestOffscreenAttention(for channel: any ChannelController, type: String, tool: String?) -> Bool {
        guard Self.offscreenAttentionKind(type: type, tool: tool) != nil else { return false }
        guard !mutedNotificationChannelIds.contains(channel.channelId) else { return false }
        return windowController?.activeChannelId != channel.channelId
    }

    private func requestOffscreenAttention(type: String, tool: String?, channel: any ChannelController) {
        updateDockBadge()
        dockAttentionClient.requestUserAttention()
        sendDesktopNotification(type: type, tool: tool, channel: channel)
    }

    private func sendDesktopNotification(type: String, tool: String?, channel: any ChannelController) {
        let content = UNMutableNotificationContent()
        switch Self.offscreenAttentionKind(type: type, tool: tool) {
        case .needsApproval:
            content.title = "Permission Needed"
            content.body = "\(channel.displayLabel) is waiting for approval"
        case .ready:
            content.title = "Task Complete"
            content.body = "\(channel.displayLabel) is ready for input"
        case .running, .error, .stale, .disconnected, .none:
            content.title = "Holoscape"
            content.body = "\(channel.displayLabel): \(type)"
        }
        content.sound = .default
        content.threadIdentifier = channel.channelId.uuidString
        content.userInfo = ["channelId": channel.channelId.uuidString]

        let request = UNNotificationRequest(identifier: channel.channelId.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Clear notification state when switching to a channel
    func clearNotification(for channelId: UUID) {
        channelNotifications.removeValue(forKey: channelId)
        updateDockBadge()
    }

    func isNotificationMuted(for channelId: UUID) -> Bool {
        mutedNotificationChannelIds.contains(channelId)
    }

    func setNotificationMuted(_ muted: Bool, for channelId: UUID) {
        if muted {
            mutedNotificationChannelIds.insert(channelId)
        } else {
            mutedNotificationChannelIds.remove(channelId)
        }
        updateDockBadge()
    }

    func toggleNotificationMuted(for channelId: UUID) -> Bool {
        let newValue = !isNotificationMuted(for: channelId)
        setNotificationMuted(newValue, for: channelId)
        return newValue
    }

    static func dockBadgeLabel(
        notificationChannelIds: some Collection<UUID>,
        mutedChannelIds: Set<UUID>,
        activeChannelId: UUID?
    ) -> String? {
        let count = notificationChannelIds.filter {
            !mutedChannelIds.contains($0) && $0 != activeChannelId
        }.count
        return count > 0 ? "\(count)" : nil
    }

    private func updateDockBadge() {
        dockAttentionClient.badgeLabel = Self.dockBadgeLabel(
            notificationChannelIds: channelNotifications.keys,
            mutedChannelIds: mutedNotificationChannelIds,
            activeChannelId: windowController?.activeChannelId
        )
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
