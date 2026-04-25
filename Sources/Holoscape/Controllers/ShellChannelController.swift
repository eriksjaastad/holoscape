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
    private let explicitLabel: String?
    private(set) var workingDirectory: String?
    private var directoryTracker: ShellDirectoryTracker
    private(set) var activatedAt: Date?

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

    var contentView: NSView { terminalView }

    init(id: UUID, instanceNumber: Int?, label: String? = nil, workingDirectory: String? = nil) {
        self.channelId = id
        self.instanceNumber = instanceNumber
        self.explicitLabel = label
        self.workingDirectory = workingDirectory
        self.directoryTracker = ShellDirectoryTracker(currentDirectory: workingDirectory)
        self.terminalView = HoloscapeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        terminalView.processDelegate = self
        terminalView.onUserInput = { [weak self] data in
            self?.handleUserInput(data)
        }
        // Output notifications handled by Claude Code hooks (idle_prompt, permission_prompt)
        // rangeChanged is too noisy for unread detection (fires on cursor blinks, redraws)
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
        // Apple_Terminal for OSC 7 directory notifications from zsh
        env["TERM_PROGRAM"] = "Apple_Terminal"
        let envPairs = env.map { "\($0.key)=\($0.value)" }

        // Wire output notifications so channelDidReceiveOutput fires when the
        // shell produces output — this drives the hasUnread / bullet indicator.
        terminalView.onOutput = { [weak self] in
            guard let self else { return }
            self.delegate?.channelDidReceiveOutput(self)
        }

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
        terminalView.onOutput = nil
        state = .disconnected
        delegate?.channelStateDidChange(self, to: .disconnected)
    }

    func retry() {
        activate()
    }

    func lastLines(_ count: Int) -> [String] {
        guard let terminal = terminalView.terminal else { return [] }
        // SwiftTerm's getText(start:end:) uses buffer-absolute row indexing.
        // Read from row 0 up to the bottom of the visible area — getText
        // returns empty for rows beyond the cursor, so this is safe even when
        // the buffer has fewer lines than `count`. We take the last `count`
        // lines from the result via .suffix().
        let bottomRow = terminal.buffer.yDisp + terminal.rows - 1
        let text = terminal.getText(
            start: Position(col: 0, row: 0),
            end: Position(col: terminal.cols - 1, row: bottomRow)
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
            if let nextDirectory = self.directoryTracker.applyHostDirectoryUpdate(directory) {
                self.updateWorkingDirectory(nextDirectory)
            }
        }
    }

    private func handleUserInput(_ data: ArraySlice<UInt8>) {
        guard let nextDirectory = directoryTracker.consume(data: data) else { return }
        updateWorkingDirectory(nextDirectory)
    }

    private func updateWorkingDirectory(_ nextDirectory: String) {
        guard nextDirectory != workingDirectory else { return }
        workingDirectory = nextDirectory
        delegate?.channelStateDidChange(self, to: state)
    }
}
