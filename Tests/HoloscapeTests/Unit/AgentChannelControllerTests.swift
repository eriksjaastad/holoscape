import XCTest
@testable import Holoscape

@MainActor
final class AgentChannelControllerTests: XCTestCase {
    private final class RecordingBrokerSessionCoordinator: BrokerSessionCoordinating {
        struct StartCall: Equatable {
            let request: BrokerSessionLaunchRequest
            let channelType: ChannelType
            let label: String?
            let attachedChannelID: UUID?
        }

        var startCalls: [StartCall] = []
        var detachCalls: [BrokerSessionID] = []

        func start(
            _ request: BrokerSessionLaunchRequest,
            channelType: ChannelType,
            label: String?,
            attachedChannelID: UUID?
        ) throws -> BrokerSessionRecord {
            startCalls.append(StartCall(request: request, channelType: channelType, label: label, attachedChannelID: attachedChannelID))
            return BrokerSessionRecord(
                id: BrokerSessionID(rawValue: "recording-agent-broker-session"),
                channelType: channelType,
                label: label,
                command: request.command,
                arguments: request.arguments,
                workingDirectory: request.workingDirectory,
                environmentProfile: request.environmentProfile,
                lifecycle: .running,
                exitCode: nil,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1),
                lastAttachedChannelID: attachedChannelID
            )
        }

        func detach(_ id: BrokerSessionID) throws -> BrokerSessionRecord {
            detachCalls.append(id)
            return BrokerSessionRecord(
                id: id,
                channelType: .agentDirect,
                label: "Codex",
                command: "/usr/bin/env",
                arguments: ["codex"],
                workingDirectory: nil,
                environmentProfile: .agentOAuth,
                lifecycle: .detached,
                exitCode: nil,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2),
                lastAttachedChannelID: nil
            )
        }

        func reattach(_ id: BrokerSessionID, attachedChannelID: UUID) throws -> BrokerSessionRecord { throw XCTSkip("unused") }
        func reattachableSessions() throws -> [BrokerSessionRecord] { [] }
        func exit(_ id: BrokerSessionID, exitCode: Int32) throws -> BrokerSessionRecord { throw XCTSkip("unused") }
        func markErrored(_ id: BrokerSessionID) throws -> BrokerSessionRecord { throw XCTSkip("unused") }
        func sendInput(_ id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(_ id: BrokerSessionID) throws -> Data { Data() }
        func readScrollbackTail(_ id: BrokerSessionID, maxBytes: Int) throws -> Data { Data() }
        func resize(_ id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(_ id: BrokerSessionID) throws -> Bool { true }
        func terminationStatus(_ id: BrokerSessionID) throws -> Int32? { nil }
        func reconcileRuntimeStatus(_ id: BrokerSessionID) throws -> BrokerSessionRecord { throw XCTSkip("unused") }
    }

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

    func testBrokerBackedAgentUsesTerminalProcessBrokerInsteadOfDoubleRecording() {
        let coordinator = RecordingBrokerSessionCoordinator()
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000000818")!
        let controller = AgentChannelController.brokerBacked(
            id: channelID,
            authType: .oauth,
            workingDirectory: URL(fileURLWithPath: "/tmp/agent-broker-backed"),
            userLabel: "Codex",
            instanceNumber: nil,
            command: "codex",
            coordinator: coordinator
        )

        controller.activate()
        defer { controller.deactivate() }

        XCTAssertEqual(coordinator.startCalls.count, 1)
        let call = coordinator.startCalls[0]
        XCTAssertEqual(call.channelType, .agentDirect)
        XCTAssertEqual(call.label, "Codex")
        XCTAssertEqual(call.attachedChannelID, channelID)
        XCTAssertEqual(call.request.command, "/usr/bin/env")
        XCTAssertEqual(call.request.arguments, ["codex"])
        XCTAssertEqual(call.request.workingDirectory, "/tmp/agent-broker-backed")
        XCTAssertEqual(call.request.environmentProfile, .agentOAuth)
        XCTAssertEqual(controller.brokerSessionID, BrokerSessionID(rawValue: "recording-agent-broker-session"))
    }

    func testActivationMarksAgentStaleWhenRestoredBrokerSessionIsMissing() {
        let terminal = MockTerminalProcess()
        terminal.startFailureDescription = "missing broker session"
        terminal.startFailureKind = .brokerSessionStale
        let delegate = MockChannelDelegate()
        let controller = AgentChannelController(
            id: UUID(),
            authType: .oauth,
            workingDirectory: nil,
            userLabel: "Codex",
            instanceNumber: nil,
            terminal: terminal
        )
        controller.delegate = delegate

        controller.activate()

        XCTAssertEqual(controller.state, .stale)
        XCTAssertEqual(delegate.stateChanges, [.connecting, .stale])
    }

    func testActivationPreservesBrokerSessionIDWhenBrokerHostIsUnavailable() {
        let preservedID = BrokerSessionID(rawValue: "agent-host-unavailable-session")
        let terminal = MockTerminalProcess()
        terminal.brokerOwnedSessionID = preservedID
        terminal.startFailureDescription = "broker host unavailable"
        terminal.startFailureKind = .brokerHostUnavailable
        let delegate = MockChannelDelegate()
        let controller = AgentChannelController(
            id: UUID(),
            authType: .oauth,
            workingDirectory: nil,
            userLabel: "Codex",
            instanceNumber: nil,
            terminal: terminal
        )
        controller.delegate = delegate

        controller.activate()

        XCTAssertEqual(controller.state, .stale)
        XCTAssertEqual(controller.brokerSessionID, preservedID)
        XCTAssertEqual(delegate.stateChanges, [.connecting, .stale])
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
