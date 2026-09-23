import AppKit
import SwiftTerm

@MainActor
class SSHChannelController: NSObject, ChannelController, LocalProcessTerminalViewDelegate {
    let channelId: UUID
    let channelType: ChannelType = .ssh
    var hasUnread: Bool = false
    private(set) var state: ChannelState = .disconnected
    let commandHistory = CommandHistory()
    weak var delegate: ChannelControllerDelegate?

    private let terminal: TerminalProcess
    private let brokerSessionCoordinator: (any BrokerSessionCoordinating)?
    private(set) var brokerSessionID: BrokerSessionID?
    let profile: SessionProfile
    private let instanceNumber: Int?
    private(set) var activatedAt: Date?
    private(set) var lastInteractionAt: Date = Date()

    var displayLabel: String {
        if let num = instanceNumber {
            return "\(profile.label) \(num)"
        }
        return profile.label
    }

    var tabIdentityIndicator: ChannelTabIdentityIndicator? { .ssh }

    var contentView: NSView { terminal.terminalContentView }

    init(
        id: UUID,
        profile: SessionProfile,
        instanceNumber: Int?,
        terminal: TerminalProcess? = nil,
        brokerSessionCoordinator: (any BrokerSessionCoordinating)? = nil
    ) {
        self.channelId = id
        self.profile = profile
        self.instanceNumber = instanceNumber
        self.terminal = terminal ?? HoloscapeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.brokerSessionCoordinator = brokerSessionCoordinator
        super.init()
        if let termView = self.terminal as? LocalProcessTerminalView {
            termView.processDelegate = self
        }
        self.terminal.setUserInputHandler { [weak self] _ in
            self?.recordUserInteraction()
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

        guard let host = profile.host, !host.isEmpty,
              let user = profile.user, !user.isEmpty else {
            state = .disconnected
            delegate?.channelStateDidChange(self, to: .disconnected)
            return
        }

        let sshArgs = buildSSHArgs(host: host, user: user, directory: profile.directory, command: profile.command)
        let env = buildSSHEnvironment()

        terminal.setOutputHandler { [weak self] in
            guard let self else { return }
            self.delegate?.channelDidReceiveOutput(self)
        }

        guard recordBrokerStart(
            arguments: sshArgs,
            label: profile.label,
            workingDirectory: profile.directory
        ) else {
            state = .disconnected
            delegate?.channelStateDidChange(self, to: .disconnected)
            return
        }

        terminal.startProcess(
            executable: "/usr/bin/ssh",
            args: sshArgs,
            environment: env,
            execName: "ssh",
            currentDirectory: nil
        )
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
        terminal.setOutputHandler(nil)
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
            self?.handleProcessTermination(exitCode: exitCode)
        }
    }

    /// Broker/state bookkeeping for a terminated ssh process.
    ///
    /// Extracted from the SwiftTerm delegate callback so the exit path has exactly
    /// one implementation and can be exercised without an AppKit terminal view.
    func handleProcessTermination(exitCode: Int32?) {
        recordBrokerExit(exitCode: exitCode)
        state = .disconnected
        delegate?.channelStateDidChange(self, to: .disconnected)
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// Shell-escape a string for safe use in a remote command.
    func shellEscape(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Build a filtered environment for the SSH subprocess.
    func buildSSHEnvironment() -> [String] {
        let allowedKeys: Set<String> = ["PATH", "HOME", "SHELL", "TERM", "LANG", "SSH_AUTH_SOCK"]
        return ProcessInfo.processInfo.environment
            .filter { allowedKeys.contains($0.key) }
            .map { "\($0.key)=\($0.value)" }
    }

    /// Build SSH command-line arguments for connecting to a remote host.
    func buildSSHArgs(host: String, user: String, directory: String, command: String) -> [String] {
        let remoteCommand: String
        if let directoryExpression = shellDirectoryExpression(directory) {
            remoteCommand = "cd \(directoryExpression) && \(command)"
        } else {
            remoteCommand = command
        }
        return ["-t", "\(user)@\(host)", remoteCommand]
    }

    func shellDirectoryExpression(_ directory: String) -> String? {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "~" else { return nil }
        guard trimmed.hasPrefix("~/") else {
            return shellEscape(trimmed)
        }

        let suffix = String(trimmed.dropFirst(2))
        guard !suffix.isEmpty else { return nil }
        return "\"$HOME\"/\(shellEscape(suffix))"
    }

    private func recordBrokerStart(
        arguments: [String],
        label: String?,
        workingDirectory: String?
    ) -> Bool {
        guard let brokerSessionCoordinator else { return true }
        let request = BrokerSessionLaunchRequest(
            command: "/usr/bin/ssh",
            arguments: arguments,
            workingDirectory: workingDirectory,
            environmentProfile: .ssh,
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
            // SSH channels own their broker metadata directly, so a broker host
            // outage is an expected runtime condition here. Report it and let
            // activate() take its explicit disconnected/reconnect path instead of
            // trapping the app.
            NSLog("SSH broker session start failed: \(error)")
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
            NSLog("SSH broker session detach failed: \(error)")
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
            NSLog("SSH broker session exit failed: \(error)")
        }
    }
}
