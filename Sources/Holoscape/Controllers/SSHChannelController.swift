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

    private let terminalView: LocalProcessTerminalView
    let profile: SessionProfile
    private let instanceNumber: Int?
    private(set) var activatedAt: Date?

    var displayLabel: String {
        if let num = instanceNumber {
            return "\(profile.label) \(num)"
        }
        return profile.label
    }

    var contentView: NSView { terminalView }

    init(id: UUID, profile: SessionProfile, instanceNumber: Int?) {
        self.channelId = id
        self.profile = profile
        self.instanceNumber = instanceNumber
        self.terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        terminalView.processDelegate = self
    }

    func sendInput(_ text: String) {
        guard state == .active else { return }
        commandHistory.add(text)
        let bytes = Array((text + "\n").utf8)
        terminalView.send(bytes)
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

        let escapedDir = shellEscape(profile.directory)
        let remoteCommand = "cd \(escapedDir) && \(profile.command)"
        let sshArgs = ["-t", "\(user)@\(host)", remoteCommand]

        // Pass through SSH_AUTH_SOCK for system SSH agent + minimal env
        let allowedKeys: Set<String> = ["PATH", "HOME", "SHELL", "TERM", "LANG", "SSH_AUTH_SOCK"]
        let env = ProcessInfo.processInfo.environment
            .filter { allowedKeys.contains($0.key) }
            .map { "\($0.key)=\($0.value)" }

        terminalView.startProcess(
            executable: "/usr/bin/ssh",
            args: sshArgs,
            environment: env,
            execName: "ssh"
        )
        state = .active
        activatedAt = Date()
        delegate?.channelStateDidChange(self, to: .active)
    }

    func deactivate() {
        state = .disconnected
        delegate?.channelStateDidChange(self, to: .disconnected)
    }

    func retry() {
        activate()
    }

    func lastLines(_ count: Int) -> [String] {
        let terminal = terminalView.terminal!
        let text = terminal.getText(
            start: Position(col: 0, row: 0),
            end: Position(col: terminal.cols - 1, row: Int.max / 2)
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
    private func shellEscape(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
