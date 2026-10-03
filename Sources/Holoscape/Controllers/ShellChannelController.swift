import AppKit
import SwiftTerm

@MainActor
class ShellChannelController: NSObject, ChannelController, LocalProcessTerminalViewDelegate {
    let channelId: UUID
    let channelType: ChannelType = .shell
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
    let instanceNumber: Int?
    private let explicitLabel: String?
    private(set) var customDisplayLabel: String?
    private(set) var workingDirectory: String?
    private var directoryTracker: ShellDirectoryTracker
    /// Last directory durably acknowledged by the process owner. Channel metadata
    /// and replacement launches use this value rather than speculative presentation
    /// state inferred from typed input before the shell reports OSC 7 truth.
    private(set) var persistedWorkingDirectory: String?
    private(set) var activatedAt: Date?
    private(set) var lastInteractionAt: Date = Date()
    private var lastStartFailureKind: TerminalStartFailureKind?

    var notificationDirectoryPath: String? {
        workingDirectory
    }

    var displayBaseLabel: String {
        if let customDisplayLabel {
            return customDisplayLabel
        }
        let base: String
        if let dir = workingDirectory {
            let directoryLabel = URL(fileURLWithPath: dir).lastPathComponent
            if let label = explicitLabel,
               !Self.isGenericShellLabel(label),
               label != directoryLabel {
                base = label
            } else {
                base = directoryLabel
            }
        } else if let label = explicitLabel, !Self.isGenericShellLabel(label) {
            base = label
        } else {
            base = "Shell"
        }
        return ChannelGitBranchLabel.decorate(base, workingDirectory: workingDirectory)
    }

    var displayLabel: String {
        let base = displayBaseLabel
        if customDisplayLabel != nil {
            return base
        }
        if let n = instanceNumber {
            return "\(base) \(n)"
        }
        return base
    }

    private static func isGenericShellLabel(_ label: String) -> Bool {
        label.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Shell") == .orderedSame
    }

    func setCustomDisplayLabel(_ label: String?) {
        customDisplayLabel = ChannelCustomDisplayLabel.normalized(label)
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
        instanceNumber: Int?,
        label: String? = nil,
        workingDirectory: String? = nil,
        existingBrokerSessionID: BrokerSessionID? = nil,
        restoredStaleBrokerSessionID: BrokerSessionID? = nil,
        coordinator: (any BrokerSessionCoordinating)? = nil
    ) -> ShellChannelController {
        let terminal = BrokerBackedTerminalProcess(
            channelID: id,
            channelType: .shell,
            label: label,
            environmentProfile: .shell,
            existingBrokerSessionID: existingBrokerSessionID,
            coordinator: coordinator ?? BrokerSessionCoordinator(runtime: BrokerSessionHostClientRuntime.currentExecutableHostRuntime())
        )
        return ShellChannelController(
            id: id,
            instanceNumber: instanceNumber,
            label: label,
            workingDirectory: workingDirectory,
            terminal: terminal,
            brokerSessionCoordinator: nil,
            restoredStaleBrokerSessionID: restoredStaleBrokerSessionID
        )
    }

    init(
        id: UUID,
        instanceNumber: Int?,
        label: String? = nil,
        workingDirectory: String? = nil,
        terminal: TerminalProcess? = nil,
        brokerSessionCoordinator: (any BrokerSessionCoordinating)? = nil,
        restoredStaleBrokerSessionID: BrokerSessionID? = nil
    ) {
        self.channelId = id
        self.instanceNumber = instanceNumber
        self.explicitLabel = label
        let directoryTracker = ShellDirectoryTracker(currentDirectory: workingDirectory)
        self.workingDirectory = directoryTracker.currentDirectory
        self.directoryTracker = directoryTracker
        self.persistedWorkingDirectory = directoryTracker.currentDirectory
        self.terminal = terminal ?? HoloscapeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.brokerSessionCoordinator = brokerSessionCoordinator
        super.init()
        if let terminalView = self.terminal as? LocalProcessTerminalView {
            terminalView.processDelegate = self
        }
        self.terminal.setUserInputHandler { [weak self] data in
            self?.handleUserInput(data)
        }
        self.terminal.setHostCurrentDirectoryHandler { [weak self] directory in
            self?.handleHostCurrentDirectoryUpdate(directory)
        }
        self.terminal.setSessionFailureHandler { [weak self] failure in
            self?.handleSessionFailure(failure)
        }
        self.terminal.setStartCompletionHandler { [weak self] in
            self?.finishActivation()
        }
        self.terminal.setTerminationHandler { [weak self] exitCode in
            guard let self else { return }
            self.recordBrokerExit(exitCode: exitCode)
            self.state = .disconnected
            self.delegate?.channelStateDidChange(self, to: .disconnected)
        }
        // Output notifications handled by Claude Code hooks (idle_prompt, permission_prompt)
        // rangeChanged is too noisy for unread detection (fires on cursor blinks, redraws)

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

        let launchDirectory = persistedWorkingDirectory
        if terminal.brokerOwnedSessionID == nil, workingDirectory != launchDirectory {
            let tracker = ShellDirectoryTracker(currentDirectory: launchDirectory)
            directoryTracker = tracker
            workingDirectory = tracker.currentDirectory
        }

        let shell = "/bin/zsh"
        let env = Self.launchEnvironment(from: ProcessInfo.processInfo.environment)
        let envPairs = env.map { "\($0.key)=\($0.value)" }

        // Wire output notifications so channelDidReceiveOutput fires when the
        // shell produces output — this drives the hasUnread / bullet indicator.
        terminal.setOutputHandler { [weak self] in
            guard let self else { return }
            self.delegate?.channelDidReceiveOutput(self)
        }

        guard recordBrokerStart(
            command: shell,
            arguments: ["-o", "nopromptsp", "--login"],
            environmentProfile: .shell,
            label: explicitLabel,
            workingDirectory: launchDirectory
        ) else {
            state = .disconnected
            delegate?.channelStateDidChange(self, to: .disconnected)
            return
        }

        terminal.startProcess(
            executable: shell,
            args: ["-o", "nopromptsp", "--login"],
            environment: envPairs,
            execName: "zsh",
            currentDirectory: launchDirectory
        )
        if terminal.completesStartAsynchronously { return }
        finishActivation()
    }

    private func finishActivation() {
        if let startFailure = terminal.startFailureDescription {
            NSLog("Shell terminal start failed: \(startFailure)")
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

    static func launchEnvironment(from parentEnvironment: [String: String]) -> [String: String] {
        var environment = parentEnvironment
        // Status ownership belongs only to an agent process launched by its tab.
        // Never let a shell inherit the token of the process that launched Holoscape.
        environment["HOLOSCAPE_AGENT_STATUS_OWNER_TOKEN"] = nil
        // Apple_Terminal for OSC 7 directory notifications from zsh.
        environment["TERM_PROGRAM"] = "Apple_Terminal"
        return environment
    }

    func deactivate() {
        deactivate(completion: {})
    }

    func deactivate(completion: @escaping @MainActor () -> Void) {
        terminal.setOutputHandler(nil)
        terminal.detachBrokerSession(completion: completion)
        recordBrokerDetach()
        state = .disconnected
        delegate?.channelStateDidChange(self, to: .disconnected)
    }

    func retry() {
        activate()
    }

    func lastLines(_ count: Int) -> [String] {
        terminal.lastLines(count)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor [weak self] in
            self?.terminal.resizeToCurrentGrid()
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.recordBrokerExit(exitCode: exitCode)
            self.state = .disconnected
            self.delegate?.channelStateDidChange(self, to: .disconnected)
        }
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Could update tab label with terminal title
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        Task { @MainActor [weak self] in
            self?.handleHostCurrentDirectoryUpdate(directory)
        }
    }

    private func handleHostCurrentDirectoryUpdate(_ directory: String?) {
        guard let nextDirectory = directoryTracker.applyHostDirectoryUpdate(directory) else { return }
        updateWorkingDirectory(nextDirectory, persistConfirmedDirectory: true)
    }

    private func handleUserInput(_ data: ArraySlice<UInt8>) {
        recordUserInteraction()
        guard let nextDirectory = directoryTracker.consume(data: data) else { return }
        updateWorkingDirectory(nextDirectory, persistConfirmedDirectory: false)
    }

    func recordUserInteraction(at date: Date = Date()) {
        lastInteractionAt = date
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

    private func updateWorkingDirectory(
        _ nextDirectory: String,
        persistConfirmedDirectory: Bool
    ) {
        let presentationChanged = nextDirectory != workingDirectory
        if presentationChanged {
            workingDirectory = nextDirectory
        }

        var durableDirectoryChanged = false
        if persistConfirmedDirectory, nextDirectory != persistedWorkingDirectory {
            do {
                try terminal.updateWorkingDirectory(nextDirectory)
                persistedWorkingDirectory = nextDirectory
                durableDirectoryChanged = true
            } catch {
                // Keep durable launch/config truth unchanged so a failed broker
                // write cannot be presented as persisted. Repeated host truth retries.
                NSLog("Shell broker working-directory update failed: \(error)")
            }
        }

        if presentationChanged || durableDirectoryChanged {
            delegate?.channelStateDidChange(self, to: state)
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
            // (test-injected shells today; production shells use the broker-backed
            // terminal instead). A broker host outage here is an expected runtime
            // condition, so report it and let the caller take its explicit
            // disconnected/reconnect path instead of trapping.
            NSLog("Shell broker session start failed: \(error)")
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
            NSLog("Shell broker session detach failed: \(error)")
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
            NSLog("Shell broker session exit failed: \(error)")
        }
    }
}
