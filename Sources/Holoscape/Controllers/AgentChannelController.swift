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

    private let terminalView: HoloscapeTerminalView
    private let authType: AgentAuthType
    private let workingDirectory: URL?
    private let userLabel: String?
    private var detectedRole: String?
    private let instanceNumber: Int?
    private let useRawLabel: Bool
    private(set) var activatedAt: Date?

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

    var contentView: NSView { terminalView }

    init(
        id: UUID,
        authType: AgentAuthType,
        workingDirectory: URL?,
        userLabel: String?,
        instanceNumber: Int?,
        useRawLabel: Bool = false
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
        self.instanceNumber = instanceNumber
        self.useRawLabel = useRawLabel
        self.terminalView = HoloscapeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        terminalView.processDelegate = self
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
        terminalView.send(bytes)
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

        // Find claude CLI
        let claudePath = "/opt/homebrew/bin/claude"

        terminalView.startProcess(
            executable: claudePath,
            args: [],
            environment: envPairs,
            execName: "claude",
            currentDirectory: workingDirectory?.path
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
}
