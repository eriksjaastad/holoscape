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

    private let terminalView: HoloscapeTerminalView
    private let instanceNumber: Int?
    private(set) var workingDirectory: String?
    private(set) var activatedAt: Date?

    var displayLabel: String {
        if let dir = workingDirectory {
            return URL(fileURLWithPath: dir).lastPathComponent
        }
        return "Shell"
    }

    var contentView: NSView { terminalView }

    init(id: UUID, instanceNumber: Int?, label: String? = nil, workingDirectory: String? = nil) {
        self.channelId = id
        self.instanceNumber = instanceNumber
        self.workingDirectory = workingDirectory
        self.terminalView = HoloscapeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        terminalView.processDelegate = self
        terminalView.onOutput = { [weak self] in
            guard let self else { return }
            self.delegate?.channelDidReceiveOutput(self)
        }
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

        let shell = "/bin/zsh"
        var env = ProcessInfo.processInfo.environment
        // Apple_Terminal triggers macOS zsh's built-in OSC 7 directory notifications
        env["TERM_PROGRAM"] = "Apple_Terminal"
        // Suppress PROMPT_SP (the % partial-line indicator) that Apple_Terminal enables
        env["HOLOSCAPE_SUPPRESS_PROMPT_SP"] = "1"
        let envPairs = env.map { "\($0.key)=\($0.value)" }

        terminalView.startProcess(
            executable: shell,
            args: ["-o", "nopromptsp", "--login"],
            environment: envPairs,
            execName: "zsh",
            currentDirectory: workingDirectory
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
        // getText clamps end.row to buffer size, so use Int.max as upper bound
        let text = terminal.getText(
            start: Position(col: 0, row: 0),
            end: Position(col: terminal.cols - 1, row: Int.max / 2)
        )
        let lines = text.components(separatedBy: "\n")
        return Array(lines.suffix(count))
    }

    // MARK: - LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // Terminal resized — SwiftTerm handles this internally
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
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
            // OSC 7 sends file:// URLs — extract the path
            if let dir = directory, let url = URL(string: dir), url.scheme == "file" {
                self.workingDirectory = url.path
            } else {
                self.workingDirectory = directory
            }
            self.delegate?.channelStateDidChange(self, to: self.state)
        }
    }
}
