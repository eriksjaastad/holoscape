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
    /// Broker session this tab could not reattach because the broker no longer
    /// owns it. Retained (and persisted) while the tab is stale so the recreate
    /// guidance and the tab/session association survive relaunch/restore.
    private(set) var staleBrokerSessionID: BrokerSessionID?
    private let authType: AgentAuthType
    private let workingDirectory: URL?
    private let userLabel: String?
    private let command: String
    private var detectedRole: String?
    private let instanceNumber: Int?
    private let useRawLabel: Bool
    private(set) var activatedAt: Date?
    private(set) var lastInteractionAt: Date = Date()
    private(set) var adapterPersistentState: PersistentChannelState?
    private(set) var terminalOutputPersistentState: PersistentChannelState?
    private var lastStartFailureKind: TerminalStartFailureKind?

    var persistentState: PersistentChannelState {
        let runtimeState = PersistentChannelState.fromRuntimeState(
            state,
            source: staleBrokerSessionID == nil ? .processLifecycle : .brokerRegistry,
            recoveryAction: recoveryAction
        )
        return [runtimeState, adapterPersistentState, terminalOutputPersistentState]
            .compactMap { $0 }
            .max { lhs, rhs in lhs.kind.displayPriority < rhs.kind.displayPriority }
            ?? runtimeState
    }

    var notificationDirectoryPath: String? {
        workingDirectory?.path
    }

    var persistedWorkingDirectory: String? {
        workingDirectory?.path
    }

    var persistedCommand: String {
        command
    }

    var displayBaseLabel: String {
        if useRawLabel, let label = userLabel {
            return label
        }
        if let role = detectedRole ?? userLabel {
            let short = RoleDetector.shortLabel(for: role)
            if role.lowercased().contains("floor manager"),
               let dir = workingDirectory {
                return "\(short)-\(dir.lastPathComponent)"
            }
            return short
        }
        return "Agent"
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

    var tabIdentityIndicator: ChannelTabIdentityIndicator? {
        ChannelTabIdentityIndicator.detect(from: [command, userLabel, detectedRole, displayLabel])
    }

    var contentView: NSView { terminal.terminalContentView }

    var recoveryAction: ChannelRecoveryAction? {
        guard state == .disconnected || state == .stale else { return nil }
        switch lastStartFailureKind {
        case .brokerHostUnavailable:
            return .retryBrokerHost
        case .brokerSessionStale:
            return .recreateBrokerSession
        case .failed, .none:
            return state == .disconnected ? .reconnect : nil
        }
    }

    static func brokerBacked(
        id: UUID,
        authType: AgentAuthType,
        workingDirectory: URL?,
        userLabel: String?,
        instanceNumber: Int?,
        useRawLabel: Bool = false,
        command: String = "claude",
        existingBrokerSessionID: BrokerSessionID? = nil,
        restoredStaleBrokerSessionID: BrokerSessionID? = nil,
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
            brokerSessionCoordinator: nil,
            restoredStaleBrokerSessionID: restoredStaleBrokerSessionID
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
        brokerSessionCoordinator: (any BrokerSessionCoordinating)? = nil,
        restoredStaleBrokerSessionID: BrokerSessionID? = nil
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
        self.terminal.setUserInputHandler { [weak self] _ in
            guard let self else { return }
            self.recordUserInteraction()
            self.clearTerminalOutputPersistentState()
        }
        self.terminal.setSessionFailureHandler { [weak self] failure in
            self?.handleSessionFailure(failure)
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

        // A tab whose broker session the broker no longer owns comes back stale
        // with the same recreate guidance it showed before the app quit. It does
        // not activate: starting a replacement here would be a silent substitute
        // for the recovery action the guidance promises.
        if let restoredStaleBrokerSessionID {
            self.staleBrokerSessionID = restoredStaleBrokerSessionID
            self.lastStartFailureKind = .brokerSessionStale
            self.state = .stale
        }
    }

    func sendInput(_ text: String) {
        guard state == .active else { return }
        recordUserInteraction()
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
            self.refreshTerminalOutputPersistentState()
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
            let failedState = applyBrokerFailure(kind: terminal.startFailureKind)
            state = failedState
            delegate?.channelStateDidChange(self, to: failedState)
            return
        }
        if let terminalBrokerSessionID = terminal.brokerOwnedSessionID {
            brokerSessionID = terminalBrokerSessionID
        }
        lastStartFailureKind = nil
        staleBrokerSessionID = nil
        state = .active
        let now = Date()
        activatedAt = now
        recordUserInteraction(at: now)
        delegate?.channelStateDidChange(self, to: .active)
    }

    func recordUserInteraction(at date: Date = Date()) {
        lastInteractionAt = date
    }

    private func refreshTerminalOutputPersistentState() {
        let detected = TerminalOutputStatusDetector.persistentState(fromLastLines: terminal.lastLines(40))
        guard detected != terminalOutputPersistentState else { return }
        terminalOutputPersistentState = detected
        delegate?.channelStateDidChange(self, to: state)
    }

    private func clearTerminalOutputPersistentState() {
        guard terminalOutputPersistentState != nil else { return }
        terminalOutputPersistentState = nil
        delegate?.channelStateDidChange(self, to: state)
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

    func applyPersistentState(_ state: PersistentChannelState) {
        guard state.kind.displayPriority >= persistentState.kind.displayPriority else {
            return
        }
        adapterPersistentState = state
        delegate?.channelStateDidChange(self, to: self.state)
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

    /// Apply a broker failure reported by the terminal — at start time or from a
    /// live session that lost its broker — to the tab's recovery fields.
    ///
    /// Keeping this in one place is what makes the guidance a tab shows depend on
    /// the failure kind rather than on when the failure was noticed: a broker host
    /// outage keeps the handle and offers `retryBrokerHost`, a dropped session
    /// keeps the dead identity and offers `recreateBrokerSession`.
    private func applyBrokerFailure(kind: TerminalStartFailureKind?) -> ChannelState {
        lastStartFailureKind = kind
        adapterPersistentState = nil
        terminalOutputPersistentState = nil
        switch kind {
        case .brokerHostUnavailable:
            // Outage is retryable: keep the handle so retry reattaches the same
            // broker session instead of spawning a replacement.
            if let terminalBrokerSessionID = terminal.brokerOwnedSessionID {
                brokerSessionID = terminalBrokerSessionID
            }
            staleBrokerSessionID = nil
        case .brokerSessionStale:
            // The broker no longer owns the session. Retry must spawn a
            // replacement, so drop the live handle, but keep the dead identity so
            // guidance and tab metadata survive relaunch.
            brokerSessionID = nil
            staleBrokerSessionID = terminal.staleBrokerSessionID
        case .failed, .none:
            // Hard failures leave whatever durable identity the tab already had;
            // only a successful attach clears it.
            break
        }
        return channelState(for: kind)
    }

    /// Downgrade a live tab whose broker host or session disappeared underneath
    /// it. Reported by the terminal process so the failure is explicit instead of
    /// being swallowed or trapping in the middle of an output poll.
    private func handleSessionFailure(_ failure: TerminalSessionFailure) {
        let downgradedState = applyBrokerFailure(kind: failure.kind)
        guard state != downgradedState else {
            // Repeated reports (further keystrokes, a layout pass) must not churn
            // the tab bar or rewrite persisted state.
            return
        }
        state = downgradedState
        delegate?.channelStateDidChange(self, to: downgradedState)
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
            // An injected coordinator means this channel owns its broker metadata
            // (test-injected agents). A broker host outage here is an expected
            // runtime condition, so report it and let the caller take its explicit
            // disconnected/reconnect path instead of trapping.
            NSLog("Agent broker session start failed: \(error)")
            return false
        }
    }

    private func recordBrokerDetach() {
        guard let brokerSessionCoordinator, let brokerSessionID else { return }
        do {
            _ = try brokerSessionCoordinator.detach(brokerSessionID)
        } catch {
            // Detach runs on tab teardown and during app termination. If the
            // broker host is unavailable, the durable record keeps its current
            // lifecycle — still reattachable and reconciled on the next launch —
            // so log loudly rather than trapping the app while it is closing.
            NSLog("Agent broker session detach failed: \(error)")
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
            // Same boundary as detach: an unavailable broker must not trap the app
            // on process exit. The unrecorded transition stays reconcilable.
            NSLog("Agent broker session exit failed: \(error)")
        }
    }
}
