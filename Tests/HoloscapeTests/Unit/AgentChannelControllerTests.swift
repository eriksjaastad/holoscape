import XCTest
@testable import Holoscape

@MainActor
final class AgentChannelControllerTests: XCTestCase {
    func testActivateUsesInjectedTerminalProcess() {
        let terminal = MockTerminalProcess()
        let controller = AgentChannelController(
            id: UUID(),
            authType: .oauth,
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            userLabel: "Codex",
            instanceNumber: nil,
            command: "codex",
            terminal: terminal
        )

        controller.activate()

        XCTAssertTrue(terminal.startProcessCalled)
        XCTAssertEqual(terminal.lastExecutable, "/usr/bin/env")
        XCTAssertEqual(terminal.lastArgs, ["codex"])
        XCTAssertEqual(terminal.lastExecName, "codex")
        XCTAssertEqual(terminal.lastCurrentDirectory, "/tmp")
        XCTAssertEqual(controller.state, .active)
    }

    func testAgentOutputHandlerRoutesThroughTerminalProcessSeam() {
        let terminal = MockTerminalProcess()
        let delegate = MockChannelDelegate()
        let controller = AgentChannelController(
            id: UUID(),
            authType: .oauth,
            workingDirectory: nil,
            userLabel: nil,
            instanceNumber: nil,
            terminal: terminal
        )
        controller.delegate = delegate

        controller.activate()
        terminal.outputHandler?()

        XCTAssertEqual(delegate.outputCount, 1)
    }

    func testAgentLastLinesUsesTerminalProcessSeam() {
        let terminal = MockTerminalProcess()
        terminal.lines = ["alpha", "beta", "gamma"]
        let controller = AgentChannelController(
            id: UUID(),
            authType: .oauth,
            workingDirectory: nil,
            userLabel: nil,
            instanceNumber: nil,
            terminal: terminal
        )

        XCTAssertEqual(controller.lastLines(2), ["beta", "gamma"])
    }

    func testLaunchInvocationUsesEnvForBareCommand() {
        let invocation = AgentChannelController.launchInvocation(for: "claude")

        XCTAssertEqual(invocation.executable, "/usr/bin/env")
        XCTAssertEqual(invocation.args, ["claude"])
        XCTAssertEqual(invocation.execName, "claude")
    }

    func testLaunchInvocationExpandsAbsoluteOrTildeCommand() {
        let invocation = AgentChannelController.launchInvocation(for: "~/.local/bin/claude")

        XCTAssertEqual(invocation.executable, "\(NSHomeDirectory())/.local/bin/claude")
        XCTAssertTrue(invocation.args.isEmpty)
        XCTAssertEqual(invocation.execName, "claude")
    }
}
