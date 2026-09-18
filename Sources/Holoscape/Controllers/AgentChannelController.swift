import AppKit
import SwiftTerm

@MainActor
class AgentChannelController: NSObject, ChannelController, LocalProcessTerminalViewDelegate {
    let channelId: UUID
    let channelType: ChannelType
    var hasUnread: Bool = false
    private(set) var state: ChannelState = .disconnected
    let commandHistory = CommandHistory()
    weak var delegate: ChannelControllerDelegate?

    private let terminal: TerminalProcess
    private let brokerSessionCoordinator: (any BrokerSessionCoordinating)?
    private(set) var brokerSessionID: BrokerSessionID?
    private let authType: AgentAuthType
    private let workingDirectory: URL?
    private let userLabel: String?
    private let command: String
    private var detectedRole: String?
    private let instanceNumber: Int?
    private let useRawLabel: Bool
    private(set) var activatedAt: Date?

    var notificationDirectoryPath: String? {
        workingDirectory?.path
    }

    var persistedWorkingDirectory: String? {
        workingDirectory?.path
    }

    var persistedCommand: String {
        command
    }

    var displayLabel: String {
        if useRawLabel, let label = userLabel {
            if let num = instanceNumber {
                return "\(label) \(num)"
            }
            return label
        }
        if let role = detectedRole ?? userLabel {
            let short = RoleDetector.shortLabel(for: role)
            if role.lowercased().contains("floor manager"),
               let dir = workingDirectory {
                return "\(short)-\(dir.lastPathComponent)"
            }
            if let num = instanceNumber {
                return "\(short)\(num)"
            }
            return short
        }
        if let num = instanceNumber {
            return "Agent \(num)"
        }
        return "Agent"
    }

    var contentView: NSView { terminal.terminalContentView }

    static func brokerBacked(
        id: UUID,
        authType: AgentAuthType,
        workingDirectory: URL?,
        userLabel: String?,
        instanceNumber: Int?,
        useRawLabel: Bool = false,
        command: String = "claude",
        existingBrokerSessionID: BrokerSessionID? = nil,
        coordinator: (any BrokerSessionCoordinating)? = nil
    ) -> AgentChannelController {
        let environmentProfile: BrokerEnvironmentProfile
        let channelType: ChannelType
        switch authType {
        case .oauth:
            environmentProfile = .agentOAuth
            channelType = .agentDirect
        case .apiKey:
            environmentProfile = .agentAPI
            channelType = .agentAPI
        }
        let terminal = BrokerBackedTerminalProcess(
            channelID: id,
            channelType: channelType,
            label: userLabel,
            environmentProfile: environmentProfile,
            existingBrokerSessionID: existingBrokerSessionID,
            coordinator: coordinator ?? BrokerSessionCoordinator(runtime: BrokerSessionHostClientRuntime.currentExecutableHostRuntime())
        )
        return AgentChannelController(
            id: id,
            authType: authType,
            workingDirectory: workingDirectory,
            userLabel: userLabel,
            instanceNumber: instanceNumber,
            useRawLabel: useRawLabel,
            command: command,
            terminal: terminal,
            brokerSessionCoordinator: nil
        )
    }

    init(
        id: UUID,
        authType: AgentAuthType,
        workingDirectory: URL?,
        userLabel: String?,
        instanceNumber: Int?,
        useRawLabel: Bool = false,
        command: String = "claude",
        terminal: TerminalProcess? = nil,
        brokerSessionCoordinator: (any BrokerSessionCoordinating)? = nil
    ) {
        self.channelId = id
        self.authType = authType
        self.channelType = {
            switch authType {
            case .oauth: return .agentDirect
            case .apiKey: return .agentAPI
            }
        }()
        self.workingDirectory = workingDirectory
        self.userLabel = userLabel
        self.command = command
        self.instanceNumber = instanceNumber
        self.useRawLabel = useRawLabel
        self.terminal = terminal ?? HoloscapeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.brokerSessionCoordinator = brokerSessionCoordinator
        super.init()
        if let terminalView = self.terminal as? LocalProcessTerminalView {
            terminalView.processDelegate = self
        }
        self.terminal.setTerminationHandler { [weak self] exitCode in
            guard let self else { return }
            self.recordBrokerExit(exitCode: exitCode)
            self.state = .disconnected
            self.delegate?.channelStateDidChange(self, to: .disconnected)
        }
        // Output notifications handled by Claude Code hooks (idle_prompt, permission_prompt)
        // rangeChanged is too noisy for unread detection (fires on cursor blinks, redraws)

        // Detect role from CLAUDE.md if working directory provided
        if let dir = workingDirectory {
            self.detectedRole = RoleDetector.detectRole(in: dir)
        }
    }

    func sendInput(_ text: String) {
        guard state == .active else { return }
        commandHistory.add(text)
        let bytes = Array((text + "\n").utf8)
        terminal.send(bytes)
    }

    func activate() {
        state = .connecting
        delegate?.channelStateDidChange(self, to: .connecting)

        // Build clean environment with auth isolation
        let env = AuthEnvironmentBuilder.buildEnvironment(
            for: authType,
            workingDirectory: workingDirectory ?? URL(fileURLWithPath: NSHomeDirectory())
        )
        let envPairs = env.map { "\($0.key)=\($0.value)" }

        let launch = Self.launchInvocation(for: command)

        terminal.setOutputHandler { [weak self] in
            guard let self else { return }
            self.delegate?.channelDidReceiveOutput(self)
        }

        guard recordBrokerStart(
            command: launch.executable,
            arguments: launch.args,
            environmentProfile: brokerEnvironmentProfile,
            label: userLabel,
            workingDirectory: workingDirectory?.path
        ) else {
            state = .disconnected
            delegate?.channelStateDidChange(self, to: .disconnected)
            return
        }

        terminal.startProcess(
            executable: launch.executable,
            args: launch.args,
            environment: envPairs,
            execName: launch.execName,
            currentDirectory: workingDirectory?.path
        )
        if let startFailure = terminal.startFailureDescription {
            NSLog("Agent terminal start failed: \(startFailure)")
            let failedState = channelState(for: terminal.startFailureKind)
            state = failedState
            delegate?.channelStateDidChange(self, to: failedState)
            return
        }
        if let terminalBrokerSessionID = terminal.brokerOwnedSessionID {
            brokerSessionID = terminalBrokerSessionID
        }
        state = .active
        activatedAt = Date()
        delegate?.channelStateDidChange(self, to: .active)
    }

    func deactivate() {
        terminal.setOutputHandler(nil)
        terminal.detachBrokerSession()
        recordBrokerDetach()
        state = .disconnected
        delegate?.channelStateDidChange(self, to: .disconnected)
    }

    func retry() {
        activate()
    }

    static func launchInvocation(for command: String) -> (executable: String, args: [String], execName: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("/usr/bin/env", ["claude"], "claude")
        }

        if trimmed.contains(where: { $0.isWhitespace }) {
            return ("/bin/zsh", ["-lc", "exec \(trimmed)"], "zsh")
        }

        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return (expanded, [], URL(fileURLWithPath: expanded).lastPathComponent)
        }

        return ("/usr/bin/env", [trimmed], trimmed)
    }

    private func channelState(for startFailureKind: TerminalStartFailureKind?) -> ChannelState {
        switch startFailureKind {
        case .brokerHostUnavailable, .brokerSessionStale:
            return .stale
        case .failed, .none:
            return .disconnected
        }
    }

    func lastLines(_ count: Int) -> [String] {
        terminal.lastLines(count)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.recordBrokerExit(exitCode: exitCode)
            self.state = .disconnected
            self.delegate?.channelStateDidChange(self, to: .disconnected)
        }
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    private var brokerEnvironmentProfile: BrokerEnvironmentProfile {
        switch authType {
        case .oauth: return .agentOAuth
        case .apiKey: return .agentAPI
        }
    }

    private func recordBrokerStart(
        command: String,
        arguments: [String],
        environmentProfile: BrokerEnvironmentProfile,
        label: String?,
        workingDirectory: String?
    ) -> Bool {
        guard let brokerSessionCoordinator else { return true }
        let request = BrokerSessionLaunchRequest(
            command: command,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environmentProfile: environmentProfile,
            initialSize: terminal.currentGridSize
        )
        do {
            brokerSessionID = try brokerSessionCoordinator.start(
                request,
                channelType: channelType,
                label: label,
                attachedChannelID: channelId
            ).id
            return true
        } catch {
            assertionFailure("Broker session start failed: \(error)")
            return false
        }
    }

    private func recordBrokerDetach() {
        guard let brokerSessionCoordinator, let brokerSessionID else { return }
        do {
            _ = try brokerSessionCoordinator.detach(brokerSessionID)
        } catch {
            assertionFailure("Broker session detach failed: \(error)")
        }
    }

    private func recordBrokerExit(exitCode: Int32?) {
        guard let brokerSessionCoordinator, let brokerSessionID else { return }
        do {
            if let exitCode {
                _ = try brokerSessionCoordinator.exit(brokerSessionID, exitCode: exitCode)
            } else {
                _ = try brokerSessionCoordinator.markErrored(brokerSessionID)
            }
        } catch {
            assertionFailure("Broker session exit failed: \(error)")
        }
    }
}
