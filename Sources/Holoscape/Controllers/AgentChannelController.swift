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

    private let terminalView: LocalProcessTerminalView
    private let authType: AgentAuthType
    private let workingDirectory: URL?
    private let userLabel: String?
    private var detectedRole: String?
    private let instanceNumber: Int?

    var displayLabel: String {
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
        instanceNumber: Int?
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
        self.terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        terminalView.processDelegate = self

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
        // TODO: Extract from SwiftTerm buffer
        return []
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
