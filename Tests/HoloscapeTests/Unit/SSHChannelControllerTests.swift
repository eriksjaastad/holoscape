import XCTest
import AppKit
@testable import Holoscape

@MainActor
class MockTerminalProcess: TerminalProcess {
    var startProcessCalled = false
    var lastArgs: [String] = []
    var lastEnvironment: [String] = []
    var sentBytes: [[UInt8]] = []
    var terminalContentView: NSView = NSView()

    func startProcess(executable: String, args: [String], environment: [String]?, execName: String?, currentDirectory: String?) {
        startProcessCalled = true
        lastArgs = args
        lastEnvironment = environment ?? []
    }

    func send(_ bytes: [UInt8]) {
        sentBytes.append(bytes)
    }
}

@MainActor
class MockChannelDelegate: ChannelControllerDelegate {
    var stateChanges: [ChannelState] = []
    func channelStateDidChange(_ channel: any ChannelController, to state: ChannelState) {
        stateChanges.append(state)
    }
    func channelDidReceiveOutput(_ channel: any ChannelController) {}
}

final class SSHChannelControllerTests: XCTestCase {

    // MARK: - Display Label

    @MainActor
    func testDisplayLabelWithoutInstanceNumber() {
        let profile = SessionProfile(label: "architect", connection: .ssh, command: "claude", directory: "~/projects", host: "MacBook.local", user: "erik")
        let controller = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        XCTAssertEqual(controller.displayLabel, "architect")
    }

    @MainActor
    func testDisplayLabelWithInstanceNumber() {
        let profile = SessionProfile(label: "mini-claude", connection: .ssh, command: "claude", directory: "~", host: "mac-mini.local", user: "erik")
        let controller = SSHChannelController(id: UUID(), profile: profile, instanceNumber: 2)
        XCTAssertEqual(controller.displayLabel, "mini-claude 2")
    }

    @MainActor
    func testDisplayLabelProjectDirectory() {
        let profile = SessionProfile(label: "holoscape", connection: .ssh, command: "claude", directory: "~/projects/holoscape", host: "MacBook.local", user: "erik")
        let controller = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        XCTAssertEqual(controller.displayLabel, "holoscape")
    }

    // MARK: - Channel Type

    @MainActor
    func testChannelTypeIsSSH() {
        let profile = SessionProfile(label: "test", connection: .ssh, command: "claude", directory: "~", host: "host", user: "user")
        let controller = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        XCTAssertEqual(controller.channelType, .ssh)
    }

    // MARK: - Activation Guards

    @MainActor
    func testActivateWithMissingHostStaysDisconnected() {
        let profile = SessionProfile(label: "test", connection: .ssh, command: "claude", directory: "~", host: nil, user: nil)
        let controller = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        controller.activate()
        XCTAssertEqual(controller.state, .disconnected)
    }

    @MainActor
    func testActivateWithEmptyHostStaysDisconnected() {
        let profile = SessionProfile(label: "test", connection: .ssh, command: "claude", directory: "~", host: "", user: "erik")
        let controller = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        controller.activate()
        XCTAssertEqual(controller.state, .disconnected)
    }

    // MARK: - Profile Access

    @MainActor
    func testProfileIsAccessible() {
        let profile = SessionProfile(label: "architect", connection: .ssh, command: "claude", directory: "~/projects", host: "MacBook.local", user: "erik")
        let controller = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        XCTAssertEqual(controller.profile.label, "architect")
        XCTAssertEqual(controller.profile.host, "MacBook.local")
        XCTAssertEqual(controller.profile.directory, "~/projects")
    }

    // MARK: - Shell Escaping

    @MainActor func testShellEscapePlainPath() {
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        XCTAssertEqual(c.shellEscape("~/projects"), "'~/projects'")
    }

    @MainActor func testShellEscapeSingleQuoteInPath() {
        // "my'project" → "'my'\\''project'"
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        XCTAssertEqual(c.shellEscape("my'project"), "'my'\\''project'")
    }

    @MainActor func testShellEscapeSpacesInPath() {
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        XCTAssertEqual(c.shellEscape("my project"), "'my project'")
    }

    @MainActor func testShellEscapeSpecialChars() {
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        let result = c.shellEscape("path$`\\\"&;|")
        XCTAssertTrue(result.hasPrefix("'"), "Should start with single quote")
        XCTAssertTrue(result.hasSuffix("'"), "Should end with single quote")
    }

    @MainActor func testShellEscapeEmptyString() {
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        XCTAssertEqual(c.shellEscape(""), "''")
    }

    @MainActor func testShellEscapeUnicodePath() {
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        let result = c.shellEscape("~/プロジェクト")
        XCTAssertEqual(result, "'~/プロジェクト'")
    }

    // MARK: - Environment Filtering

    @MainActor func testEnvironmentOnlyContainsAllowedKeys() {
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        let env = c.buildSSHEnvironment()
        let allowedKeys: Set<String> = ["PATH", "HOME", "SHELL", "TERM", "LANG", "SSH_AUTH_SOCK"]
        for entry in env {
            let key = entry.components(separatedBy: "=").first ?? ""
            XCTAssertTrue(allowedKeys.contains(key), "Unexpected env key: \(key)")
        }
    }

    @MainActor func testEnvironmentExcludesSensitiveVars() {
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        let env = c.buildSSHEnvironment()
        let envKeys = env.map { $0.components(separatedBy: "=").first ?? "" }
        XCTAssertFalse(envKeys.contains("AWS_SECRET_ACCESS_KEY"))
        XCTAssertFalse(envKeys.contains("GITHUB_TOKEN"))
        XCTAssertFalse(envKeys.contains("ANTHROPIC_API_KEY"))
    }

    @MainActor func testSSHAuthSockPreserved() {
        // SSH_AUTH_SOCK is in the allowlist — if present in env, it should be included
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        let env = c.buildSSHEnvironment()
        let envKeys = env.map { $0.components(separatedBy: "=").first ?? "" }
        // Can't guarantee SSH_AUTH_SOCK exists, but if it does it should be included
        if ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] != nil {
            XCTAssertTrue(envKeys.contains("SSH_AUTH_SOCK"), "SSH_AUTH_SOCK should be preserved when set")
        }
    }

    @MainActor func testSSHAuthSockOmittedWhenMissing() {
        // When SSH_AUTH_SOCK is not set, env should still be valid (no crash)
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        let env = c.buildSSHEnvironment()
        XCTAssertFalse(env.isEmpty, "Environment should have at least PATH and HOME")
    }

    // MARK: - SSH Argument Construction

    @MainActor func testSSHArgsIncludeTFlag() {
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        let args = c.buildSSHArgs(host: "server.com", user: "erik", directory: "~/proj", command: "bash")
        XCTAssertEqual(args.first, "-t", "First arg should be -t for PTY allocation")
    }

    @MainActor func testSSHArgsUserAtHost() {
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        let args = c.buildSSHArgs(host: "server.com", user: "erik", directory: "~", command: "bash")
        XCTAssertEqual(args[1], "erik@server.com")
    }

    @MainActor func testSSHArgsRemoteCommand() {
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        let args = c.buildSSHArgs(host: "server.com", user: "erik", directory: "~/proj", command: "bash")
        XCTAssertTrue(args[2].contains("cd '~/proj'"), "Remote command should cd to escaped directory")
        XCTAssertTrue(args[2].contains("&& bash"), "Remote command should chain the command")
    }

    @MainActor func testSSHArgsWithCustomCommand() {
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        let args = c.buildSSHArgs(host: "h", user: "u", directory: "~", command: "zsh --login")
        XCTAssertTrue(args[2].contains("zsh --login"), "Custom command should be passed through")
    }

    @MainActor func testSSHArgsWithSpacesInDirectory() {
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        let args = c.buildSSHArgs(host: "h", user: "u", directory: "~/my project", command: "bash")
        XCTAssertTrue(args[2].contains("'~/my project'"), "Directory with spaces should be shell-escaped")
    }

    // MARK: - State Machine

    @MainActor func testInitialStateIsDisconnected() {
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        XCTAssertEqual(c.state, .disconnected, "Initial state should be disconnected")
    }

    @MainActor func testDeactivateSetsDisconnected() {
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        c.deactivate()
        XCTAssertEqual(c.state, .disconnected)
    }

    @MainActor func testActivateWithMissingUserStaysDisconnected() {
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "server", user: nil)
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        c.activate()
        XCTAssertEqual(c.state, .disconnected)
    }

    @MainActor func testActivateWithEmptyUserStaysDisconnected() {
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "server", user: "")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        c.activate()
        XCTAssertEqual(c.state, .disconnected)
    }

    // MARK: - Input Handling

    @MainActor func testSendInputGuardsDisconnectedState() {
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        // State is disconnected — sendInput should not crash
        c.sendInput("test")
        XCTAssertEqual(c.commandHistory.count, 0, "Command should not be added when disconnected")
    }

    @MainActor func testSendInputWithEmptyString() {
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        c.sendInput("")
        XCTAssertEqual(c.commandHistory.count, 0, "Empty input on disconnected should be fine")
    }

    @MainActor func testDisplayLabelWithInstanceNumber1() {
        let profile = SessionProfile(label: "server", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: 1)
        XCTAssertEqual(c.displayLabel, "server 1")
    }

    // MARK: - Delegate

    @MainActor func testDelegateNotifiedOnDeactivate() {
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        let mock = MockChannelDelegate()
        c.delegate = mock
        c.deactivate()
        XCTAssertEqual(mock.stateChanges, [.disconnected])
    }

    @MainActor func testDelegateNotifiedOnValidationFailure() {
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: nil, user: nil)
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil)
        let mock = MockChannelDelegate()
        c.delegate = mock
        c.activate()
        XCTAssertEqual(mock.stateChanges, [.connecting, .disconnected], "Should transition connecting → disconnected on validation failure")
    }

    // MARK: - Mock Terminal Tests

    @MainActor func testSendInputWhenActiveRoutesToTerminal() {
        let mock = MockTerminalProcess()
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "server.com", user: "erik")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil, terminal: mock)
        c.activate()
        XCTAssertEqual(c.state, .active)
        c.sendInput("ls -la")
        XCTAssertEqual(mock.sentBytes.count, 1)
        XCTAssertEqual(String(bytes: mock.sentBytes[0], encoding: .utf8), "ls -la\n")
    }

    @MainActor func testSendInputAddsToHistoryWhenActive() {
        let mock = MockTerminalProcess()
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "server.com", user: "erik")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil, terminal: mock)
        c.activate()
        c.sendInput("pwd")
        XCTAssertEqual(c.commandHistory.count, 1)
    }

    @MainActor func testActivatePassesCorrectArgsToProcess() {
        let mock = MockTerminalProcess()
        let profile = SessionProfile(label: "test", connection: .ssh, command: "zsh", directory: "~/projects", host: "server.com", user: "erik")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil, terminal: mock)
        c.activate()
        XCTAssertTrue(mock.startProcessCalled)
        XCTAssertEqual(mock.lastArgs[0], "-t")
        XCTAssertEqual(mock.lastArgs[1], "erik@server.com")
        XCTAssertTrue(mock.lastArgs[2].contains("cd '~/projects'"))
        XCTAssertTrue(mock.lastArgs[2].contains("&& zsh"))
    }

    @MainActor func testActivatePassesFilteredEnvironment() {
        let mock = MockTerminalProcess()
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil, terminal: mock)
        c.activate()
        let envKeys = mock.lastEnvironment.map { $0.components(separatedBy: "=").first ?? "" }
        let allowedKeys: Set<String> = ["PATH", "HOME", "SHELL", "TERM", "LANG", "SSH_AUTH_SOCK"]
        for key in envKeys {
            XCTAssertTrue(allowedKeys.contains(key), "Unexpected env key passed to process: \(key)")
        }
    }

    @MainActor func testRetryReactivatesAfterDisconnect() {
        let mock = MockTerminalProcess()
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil, terminal: mock)
        c.activate()
        XCTAssertEqual(c.state, .active)
        c.deactivate()
        XCTAssertEqual(c.state, .disconnected)
        mock.startProcessCalled = false
        c.retry()
        XCTAssertTrue(mock.startProcessCalled, "Retry should call startProcess again")
        XCTAssertEqual(c.state, .active)
    }

    @MainActor func testSendInputGuardsWhenNotActive() {
        let mock = MockTerminalProcess()
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil, terminal: mock)
        // Don't activate — state is .disconnected
        c.sendInput("should not send")
        XCTAssertTrue(mock.sentBytes.isEmpty, "Should not send bytes when disconnected")
        XCTAssertEqual(c.commandHistory.count, 0, "Should not add to history when disconnected")
    }

    @MainActor func testActivateSetsActivatedAt() {
        let mock = MockTerminalProcess()
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil, terminal: mock)
        XCTAssertNil(c.activatedAt)
        c.activate()
        XCTAssertNotNil(c.activatedAt, "activatedAt should be set after successful activate")
    }

    @MainActor func testDelegateNotifiedThroughFullLifecycle() {
        let mock = MockTerminalProcess()
        let profile = SessionProfile(label: "t", connection: .ssh, command: "bash", directory: "~", host: "h", user: "u")
        let c = SSHChannelController(id: UUID(), profile: profile, instanceNumber: nil, terminal: mock)
        let delegate = MockChannelDelegate()
        c.delegate = delegate
        c.activate()
        c.deactivate()
        XCTAssertEqual(delegate.stateChanges, [.connecting, .active, .disconnected])
    }
}
