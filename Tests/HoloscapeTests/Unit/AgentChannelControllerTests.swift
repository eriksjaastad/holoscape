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

    func testAgentAdapterStateOverridesRuntimeStateForPersistence() {
        let controller = AgentChannelController(
            id: UUID(),
            authType: .oauth,
            workingDirectory: nil,
            userLabel: "Codex",
            instanceNumber: nil,
            command: "codex",
            terminal: MockTerminalProcess()
        )
        controller.activate()
        XCTAssertEqual(controller.state, .active)

        let state = PersistentChannelState(
            kind: .needsApproval,
            source: .agentAdapter,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_020),
            reason: "codex awaiting approval"
        )
        controller.applyPersistentState(state)

        XCTAssertEqual(controller.persistentState, state)
        XCTAssertEqual(controller.state, .active, "adapter state must not fake a process lifecycle transition")
    }

    func testAgentAdapterStateClearsAfterBrokerFailureTakesOver() {
        let terminal = MockTerminalProcess()
        let controller = AgentChannelController(
            id: UUID(),
            authType: .oauth,
            workingDirectory: nil,
            userLabel: "Codex",
            instanceNumber: nil,
            command: "codex",
            terminal: terminal
        )
        controller.activate()
        controller.applyPersistentState(PersistentChannelState(kind: .needsApproval, source: .agentAdapter))

        terminal.startFailureKind = .brokerHostUnavailable
        terminal.sessionFailureHandler?(TerminalSessionFailure(kind: .brokerHostUnavailable, description: "host unavailable"))

        XCTAssertEqual(controller.state, .stale)
        XCTAssertEqual(controller.persistentState.kind, .stale)
        XCTAssertNotEqual(controller.persistentState.source, .agentAdapter)
    }

    func testPluginStatusCannotOverwriteHigherPriorityAgentAdapterState() {
        let controller = AgentChannelController(
            id: UUID(),
            authType: .oauth,
            workingDirectory: nil,
            userLabel: "Codex",
            instanceNumber: nil,
            command: "codex",
            terminal: MockTerminalProcess()
        )
        controller.activate()
        let awaitingApproval = PersistentChannelState(
            kind: .needsApproval,
            source: .agentAdapter,
            reason: "codex awaiting approval"
        )
        controller.applyPersistentState(awaitingApproval)

        controller.applyPersistentState(
            PersistentChannelState(
                kind: .ready,
                source: .plugin,
                reason: "Project Tracker healthy"
            )
        )

        XCTAssertEqual(
            controller.persistentState,
            awaitingApproval,
            "Plugin status is supplemental and must not hide higher-priority agent/operator states"
        )
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

    /// #7375 — coordinator-backed agent tabs must survive broker host loss while
    /// recording detach/exit metadata instead of trapping.
    func testCoordinatorBackedAgentDetachWithBrokerHostOutageKeepsRecordReattachable() throws {
        let fixture = try CoordinatorBackedBrokerFixture()
        defer { fixture.cleanup() }
        let terminal = MockTerminalProcess()
        let controller = AgentChannelController(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000731")!,
            authType: .oauth,
            workingDirectory: nil,
            userLabel: "Codex",
            instanceNumber: nil,
            terminal: terminal,
            brokerSessionCoordinator: fixture.coordinator
        )
        controller.activate()
        let sessionID = try XCTUnwrap(controller.brokerSessionID)

        fixture.runtime.mode = .hostUnavailable
        controller.deactivate()

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertEqual(controller.recoveryAction, .reconnect)
        XCTAssertEqual(controller.brokerSessionID, sessionID)
        XCTAssertEqual(fixture.runtime.detachedIDs, [sessionID])
        XCTAssertEqual(try fixture.singleRecord().lifecycle, .running)
    }

    func testCoordinatorBackedAgentExitWithBrokerHostOutageKeepsRecordReattachable() throws {
        let fixture = try CoordinatorBackedBrokerFixture()
        defer { fixture.cleanup() }
        let terminal = MockTerminalProcess()
        let delegate = MockChannelDelegate()
        let controller = AgentChannelController(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000732")!,
            authType: .oauth,
            workingDirectory: nil,
            userLabel: "Codex",
            instanceNumber: nil,
            terminal: terminal,
            brokerSessionCoordinator: fixture.coordinator
        )
        controller.delegate = delegate
        controller.activate()
        let sessionID = try XCTUnwrap(controller.brokerSessionID)

        fixture.runtime.mode = .hostUnavailable
        terminal.reportTermination(exitCode: nil)

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertEqual(controller.brokerSessionID, sessionID)
        XCTAssertEqual(
            fixture.runtime.erroredIDs,
            [sessionID],
            "A nil exit code must still attempt the errored transition"
        )
        XCTAssertEqual(try fixture.singleRecord().lifecycle, .running)
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
        XCTAssertEqual(controller.recoveryAction, .recreateBrokerSession)
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
        XCTAssertEqual(controller.recoveryAction, .retryBrokerHost)
        XCTAssertEqual(delegate.stateChanges, [.connecting, .stale])
    }

    /// Agent tabs must downgrade the same way shell tabs do when the broker host
    /// disappears underneath a running session.
    func testLiveAgentTabDowngradesToRetryableStaleWhenBrokerHostDisappears() {
        let preservedID = BrokerSessionID(rawValue: "agent-live-host-loss-session")
        let terminal = MockTerminalProcess()
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
        XCTAssertEqual(controller.state, .active)

        terminal.brokerOwnedSessionID = preservedID
        terminal.reportSessionFailure(kind: .brokerHostUnavailable)

        XCTAssertEqual(controller.state, .stale)
        XCTAssertEqual(controller.brokerSessionID, preservedID)
        XCTAssertNil(controller.staleBrokerSessionID)
        XCTAssertEqual(controller.recoveryAction, .retryBrokerHost)
        XCTAssertEqual(delegate.stateChanges, [.connecting, .active, .stale])

        terminal.reportSessionFailure(kind: .brokerHostUnavailable)
        controller.sendInput("echo still-here")
        XCTAssertEqual(delegate.stateChanges, [.connecting, .active, .stale])
        XCTAssertTrue(terminal.sentBytes.isEmpty)
    }

    /// A dropped session reported mid-run must offer recreate, not retry: the
    /// failure kind decides the guidance, not when it was noticed.
    func testLiveAgentTabDowngradesToRecreateWhenBrokerDropsTheSession() {
        let deadID = BrokerSessionID(rawValue: "agent-live-dropped-session")
        let terminal = MockTerminalProcess()
        let controller = AgentChannelController(
            id: UUID(),
            authType: .oauth,
            workingDirectory: nil,
            userLabel: "Codex",
            instanceNumber: nil,
            terminal: terminal
        )
        controller.activate()
        terminal.brokerOwnedSessionID = deadID
        terminal.staleBrokerSessionID = deadID

        terminal.reportSessionFailure(kind: .brokerSessionStale)

        XCTAssertEqual(controller.state, .stale)
        XCTAssertNil(controller.brokerSessionID)
        XCTAssertEqual(controller.staleBrokerSessionID, deadID)
        XCTAssertEqual(controller.recoveryAction, .recreateBrokerSession)
    }

    func testActivationRetainsStaleBrokerIdentityWhenRestoredSessionIsMissing() {
        let deadID = BrokerSessionID(rawValue: "agent-stale-restored-session")
        let terminal = MockTerminalProcess()
        terminal.staleBrokerSessionID = deadID
        terminal.startFailureDescription = "missing broker session"
        terminal.startFailureKind = .brokerSessionStale
        let controller = AgentChannelController(
            id: UUID(),
            authType: .oauth,
            workingDirectory: nil,
            userLabel: "Codex",
            instanceNumber: nil,
            terminal: terminal
        )

        controller.activate()

        XCTAssertEqual(controller.state, .stale)
        XCTAssertNil(controller.brokerSessionID)
        XCTAssertEqual(controller.staleBrokerSessionID, deadID)
        XCTAssertEqual(controller.recoveryAction, .recreateBrokerSession)
    }

    func testRestoredStaleAgentReportsRecreateGuidanceWithoutStartingAProcess() {
        let deadID = BrokerSessionID(rawValue: "agent-restored-stale-session")
        let terminal = MockTerminalProcess()
        let controller = AgentChannelController(
            id: UUID(),
            authType: .oauth,
            workingDirectory: nil,
            userLabel: "Codex",
            instanceNumber: nil,
            terminal: terminal,
            restoredStaleBrokerSessionID: deadID
        )

        XCTAssertEqual(controller.state, .stale)
        XCTAssertEqual(controller.staleBrokerSessionID, deadID)
        XCTAssertEqual(controller.recoveryAction, .recreateBrokerSession)
        XCTAssertFalse(terminal.startProcessCalled)
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
