import AppKit
import SwiftTerm

/// Protocol abstracting terminal process interaction for testability.
protocol TerminalProcess: AnyObject {
    @MainActor func startProcess(executable: String, args: [String], environment: [String]?, execName: String?, currentDirectory: String?)
    @MainActor func send(_ bytes: [UInt8])
    @MainActor var terminalContentView: NSView { get }
}

extension LocalProcessTerminalView: TerminalProcess {
    @MainActor var terminalContentView: NSView { self }
}

@MainActor
class SSHChannelController: NSObject, ChannelController, LocalProcessTerminalViewDelegate {
    let channelId: UUID
    let channelType: ChannelType = .ssh
    var hasUnread: Bool = false
    private(set) var state: ChannelState = .disconnected
    let commandHistory = CommandHistory()
    weak var delegate: ChannelControllerDelegate?

    private let terminal: TerminalProcess
    let profile: SessionProfile
    private let instanceNumber: Int?
    private(set) var activatedAt: Date?

    var displayLabel: String {
        if let num = instanceNumber {
            return "\(profile.label) \(num)"
        }
        return profile.label
    }

    var contentView: NSView { terminal.terminalContentView }

    init(id: UUID, profile: SessionProfile, instanceNumber: Int?, terminal: TerminalProcess? = nil) {
        self.channelId = id
        self.profile = profile
        self.instanceNumber = instanceNumber
        self.terminal = terminal ?? HoloscapeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        if let termView = self.terminal as? LocalProcessTerminalView {
            termView.processDelegate = self
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

        guard let host = profile.host, !host.isEmpty,
              let user = profile.user, !user.isEmpty else {
            state = .disconnected
            delegate?.channelStateDidChange(self, to: .disconnected)
            return
        }

        let sshArgs = buildSSHArgs(host: host, user: user, directory: profile.directory, command: profile.command)
        let env = buildSSHEnvironment()

        terminal.startProcess(
            executable: "/usr/bin/ssh",
            args: sshArgs,
            environment: env,
            execName: "ssh",
            currentDirectory: nil
        )
        state = .active
        activatedAt = Date()
        delegate?.channelStateDidChange(self, to: .active)
    }

    func deactivate() {
        (terminal as? HoloscapeTerminalView)?.onOutput = nil
        state = .disconnected
        delegate?.channelStateDidChange(self, to: .disconnected)
    }

    func retry() {
        activate()
    }

    func lastLines(_ count: Int) -> [String] {
        guard let termView = terminal as? LocalProcessTerminalView,
              let term = termView.terminal else { return [] }
        let text = term.getText(
            start: Position(col: 0, row: 0),
            end: Position(col: term.cols - 1, row: Int.max / 2)
        )
        let lines = text.components(separatedBy: "\n")
        return Array(lines.suffix(count))
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.state = .disconnected
            self.delegate?.channelStateDidChange(self, to: .disconnected)
        }
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
        let escapedDir = shellEscape(directory)
        let remoteCommand = "cd \(escapedDir) && \(command)"
        return ["-t", "\(user)@\(host)", remoteCommand]
    }
}
