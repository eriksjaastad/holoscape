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
    private let instanceNumber: Int?
    private let explicitLabel: String?
    private(set) var workingDirectory: String?
    private var directoryTracker: ShellDirectoryTracker
    private(set) var activatedAt: Date?
    private var lastStartFailureKind: TerminalStartFailureKind?

    var notificationDirectoryPath: String? {
        workingDirectory
    }

    var displayLabel: String {
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
        if let n = instanceNumber {
            return "\(base) \(n)"
        }
        return base
    }

    private static func isGenericShellLabel(_ label: String) -> Bool {
        label.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Shell") == .orderedSame
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
        self.workingDirectory = workingDirectory
        self.directoryTracker = ShellDirectoryTracker(currentDirectory: workingDirectory)
        self.terminal = terminal ?? HoloscapeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.brokerSessionCoordinator = brokerSessionCoordinator
        super.init()
        if let terminalView = self.terminal as? LocalProcessTerminalView {
            terminalView.processDelegate = self
        }
        self.terminal.setUserInputHandler { [weak self] data in
            self?.handleUserInput(data)
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
        commandHistory.add(text)
        let bytes = Array((text + "\n").utf8)
        terminal.send(bytes)
    }

    func activate() {
        state = .connecting
        delegate?.channelStateDidChange(self, to: .connecting)

        let shell = "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        // Apple_Terminal for OSC 7 directory notifications from zsh
        env["TERM_PROGRAM"] = "Apple_Terminal"
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
            workingDirectory: workingDirectory
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
            currentDirectory: workingDirectory
        )
        if let startFailure = terminal.startFailureDescription {
            NSLog("Shell terminal start failed: \(startFailure)")
            let failedState = channelState(for: terminal.startFailureKind)
            lastStartFailureKind = terminal.startFailureKind
            switch terminal.startFailureKind {
            case .brokerHostUnavailable:
                // Outage is retryable: keep the handle so retry reattaches the
                // same broker session instead of spawning a replacement.
                if let terminalBrokerSessionID = terminal.brokerOwnedSessionID {
                    brokerSessionID = terminalBrokerSessionID
                }
                staleBrokerSessionID = nil
            case .brokerSessionStale:
                // The broker no longer owns the session. Retry must spawn a
                // replacement, so drop the live handle, but keep the dead
                // identity so guidance and tab metadata survive relaunch.
                brokerSessionID = nil
                staleBrokerSessionID = terminal.staleBrokerSessionID
            case .failed, .none:
                // Hard failures leave whatever durable identity the tab already
                // had; only a successful attach clears it.
                break
            }
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

    func lastLines(_ count: Int) -> [String] {
        terminal.lastLines(count)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // Terminal resized — SwiftTerm handles this internally
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
            guard let self else { return }
            if let nextDirectory = self.directoryTracker.applyHostDirectoryUpdate(directory) {
                self.updateWorkingDirectory(nextDirectory)
            }
        }
    }

    private func handleUserInput(_ data: ArraySlice<UInt8>) {
        guard let nextDirectory = directoryTracker.consume(data: data) else { return }
        updateWorkingDirectory(nextDirectory)
    }

    private func channelState(for startFailureKind: TerminalStartFailureKind?) -> ChannelState {
        switch startFailureKind {
        case .brokerHostUnavailable, .brokerSessionStale:
            return .stale
        case .failed, .none:
            return .disconnected
        }
    }

    private func updateWorkingDirectory(_ nextDirectory: String) {
        guard nextDirectory != workingDirectory else { return }
        workingDirectory = nextDirectory
        delegate?.channelStateDidChange(self, to: state)
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
