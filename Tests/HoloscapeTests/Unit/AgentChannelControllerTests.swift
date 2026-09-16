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

    func testAgentActivationRecordsBrokerSessionLifecycleWhenCoordinatorIsInjected() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentChannelControllerTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let coordinator = BrokerSessionCoordinator(registry: registry, now: { Date(timeIntervalSince1970: 400) })
        let terminal = MockTerminalProcess()
        terminal.currentGridSize = TerminalGridSize(columns: 101, rows: 37)
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000000817")!
        let controller = AgentChannelController(
            id: channelID,
            authType: .oauth,
            workingDirectory: URL(fileURLWithPath: "/Users/test/agent-work"),
            userLabel: "Codex",
            instanceNumber: nil,
            command: "codex",
            terminal: terminal,
            brokerSessionCoordinator: coordinator
        )

        controller.activate()

        let running = try registry.load().agentSingle()
        XCTAssertEqual(running.id, controller.brokerSessionID)
        XCTAssertEqual(running.channelType, .agentDirect)
        XCTAssertEqual(running.label, "Codex")
        XCTAssertEqual(running.command, "/usr/bin/env")
        XCTAssertEqual(running.arguments, ["codex"])
        XCTAssertEqual(running.workingDirectory, "/Users/test/agent-work")
        XCTAssertEqual(running.environmentProfile, .agentOAuth)
        XCTAssertEqual(running.lifecycle, .running)
        XCTAssertEqual(running.lastAttachedChannelID, channelID)

        controller.deactivate()

        let detached = try registry.load().agentSingle()
        XCTAssertEqual(detached.id, running.id)
        XCTAssertEqual(detached.lifecycle, .detached)
        XCTAssertNil(detached.lastAttachedChannelID)
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

private extension Array {
    func agentSingle(file: StaticString = #filePath, line: UInt = #line) throws -> Element {
        XCTAssertEqual(count, 1, file: file, line: line)
        return self[0]
    }
}
