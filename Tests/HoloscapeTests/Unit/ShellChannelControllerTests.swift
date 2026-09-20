import XCTest
@testable import Holoscape

@MainActor
final class ShellChannelControllerTests: XCTestCase {
    func testActivateUsesInjectedTerminalProcess() {
        let terminal = MockTerminalProcess()
        let controller = ShellChannelController(
            id: UUID(),
            instanceNumber: nil,
            workingDirectory: "/tmp",
            terminal: terminal
        )

        controller.activate()

        XCTAssertTrue(terminal.startProcessCalled)
        XCTAssertEqual(terminal.lastExecutable, "/bin/zsh")
        XCTAssertEqual(terminal.lastArgs, ["-o", "nopromptsp", "--login"])
        XCTAssertEqual(terminal.lastExecName, "zsh")
        XCTAssertEqual(terminal.lastCurrentDirectory, "/tmp")
        XCTAssertEqual(controller.state, .active)
    }

    func testShellOutputHandlerRoutesThroughTerminalProcessSeam() {
        let terminal = MockTerminalProcess()
        let delegate = MockChannelDelegate()
        let controller = ShellChannelController(id: UUID(), instanceNumber: nil, terminal: terminal)
        controller.delegate = delegate

        controller.activate()
        terminal.outputHandler?()

        XCTAssertEqual(delegate.outputCount, 1)
    }

    func testShellUserInputHandlerRoutesThroughTerminalProcessSeam() {
        let terminal = MockTerminalProcess()
        let controller = ShellChannelController(
            id: UUID(),
            instanceNumber: nil,
            workingDirectory: NSHomeDirectory(),
            terminal: terminal
        )

        controller.activate()
        terminal.userInputHandler?(Array("cd /tmp\n".utf8)[...])

        XCTAssertEqual(controller.workingDirectory, "/tmp")
    }

    func testShellLastLinesUsesTerminalProcessSeam() {
        let terminal = MockTerminalProcess()
        terminal.lines = ["one", "two", "three"]
        let controller = ShellChannelController(id: UUID(), instanceNumber: nil, terminal: terminal)

        XCTAssertEqual(controller.lastLines(2), ["two", "three"])
    }

    func testShellActivationRecordsBrokerSessionLifecycleWhenCoordinatorIsInjected() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellChannelControllerTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let coordinator = BrokerSessionCoordinator(registry: registry, now: { Date(timeIntervalSince1970: 300) })
        let terminal = MockTerminalProcess()
        terminal.currentGridSize = TerminalGridSize(columns: 132, rows: 43)
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000000716")!
        let controller = ShellChannelController(
            id: channelID,
            instanceNumber: nil,
            label: "work",
            workingDirectory: "/Users/test/work",
            terminal: terminal,
            brokerSessionCoordinator: coordinator
        )

        controller.activate()

        let running = try registry.load().single()
        XCTAssertEqual(running.id, controller.brokerSessionID)
        XCTAssertEqual(running.channelType, .shell)
        XCTAssertEqual(running.label, "work")
        XCTAssertEqual(running.command, "/bin/zsh")
        XCTAssertEqual(running.arguments, ["-o", "nopromptsp", "--login"])
        XCTAssertEqual(running.workingDirectory, "/Users/test/work")
        XCTAssertEqual(running.environmentProfile, .shell)
        XCTAssertEqual(running.lifecycle, .running)
        XCTAssertEqual(running.lastAttachedChannelID, channelID)

        controller.deactivate()

        let detached = try registry.load().single()
        XCTAssertEqual(detached.id, running.id)
        XCTAssertEqual(detached.lifecycle, .detached)
        XCTAssertNil(detached.lastAttachedChannelID)
    }

    /// #7375 — a coordinator-backed shell whose broker host is unavailable must
    /// not trap while recording broker metadata; the failure stays explicit and
    /// the tab stays recoverable.
    func testCoordinatorBackedShellActivationWithBrokerHostOutageStaysRecoverable() throws {
        let fixture = try CoordinatorBackedBrokerFixture()
        defer { fixture.cleanup() }
        let terminal = MockTerminalProcess()
        let delegate = MockChannelDelegate()
        let controller = ShellChannelController(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000721")!,
            instanceNumber: nil,
            label: "work",
            workingDirectory: "/Users/test/work",
            terminal: terminal,
            brokerSessionCoordinator: fixture.coordinator
        )
        controller.delegate = delegate
        fixture.runtime.mode = .hostUnavailable

        controller.activate()

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertNil(controller.brokerSessionID)
        XCTAssertEqual(controller.recoveryAction, .reconnect)
        XCTAssertEqual(delegate.stateChanges, [.connecting, .disconnected])
        XCTAssertTrue(try fixture.records().isEmpty, "A failed broker start must not leave a phantom record")
    }

    func testCoordinatorBackedShellDetachWithBrokerHostOutageKeepsRecordReattachable() throws {
        let fixture = try CoordinatorBackedBrokerFixture()
        defer { fixture.cleanup() }
        let terminal = MockTerminalProcess()
        let controller = ShellChannelController(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000722")!,
            instanceNumber: nil,
            label: "work",
            workingDirectory: "/Users/test/work",
            terminal: terminal,
            brokerSessionCoordinator: fixture.coordinator
        )
        controller.activate()
        let sessionID = try XCTUnwrap(controller.brokerSessionID)

        fixture.runtime.mode = .hostUnavailable
        controller.deactivate()

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertEqual(controller.recoveryAction, .reconnect)
        XCTAssertEqual(controller.brokerSessionID, sessionID, "A failed detach must keep the handle for reattach")
        XCTAssertEqual(fixture.runtime.detachedIDs, [sessionID], "The detach attempt must still reach the coordinator")
        XCTAssertEqual(
            try fixture.singleRecord().lifecycle,
            .running,
            "An unrecorded detach must leave the durable record reattachable for the next launch"
        )
    }

    func testCoordinatorBackedShellExitWithBrokerHostOutageKeepsRecordReattachable() throws {
        let fixture = try CoordinatorBackedBrokerFixture()
        defer { fixture.cleanup() }
        let terminal = MockTerminalProcess()
        let delegate = MockChannelDelegate()
        let controller = ShellChannelController(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000723")!,
            instanceNumber: nil,
            label: "work",
            workingDirectory: "/Users/test/work",
            terminal: terminal,
            brokerSessionCoordinator: fixture.coordinator
        )
        controller.delegate = delegate
        controller.activate()
        let sessionID = try XCTUnwrap(controller.brokerSessionID)

        fixture.runtime.mode = .hostUnavailable
        terminal.reportTermination(exitCode: 7)

        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertEqual(controller.brokerSessionID, sessionID, "A failed exit must keep the handle for reattach")
        XCTAssertEqual(fixture.runtime.exitedIDs, [sessionID])
        XCTAssertEqual(
            try fixture.singleRecord().lifecycle,
            .running,
            "An unrecorded exit must not fabricate an exited lifecycle"
        )
    }

    func testBrokerBackedShellActivationUsesTerminalOwnedSessionWithoutDuplicateMetadata() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellChannelControllerBrokerBackedTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let coordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: NativePTYBrokerSessionRuntime(),
            now: { Date(timeIntervalSince1970: 400) }
        )
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000000717")!
        let terminal = BrokerBackedTerminalProcess(
            channelID: channelID,
            channelType: .shell,
            label: "broker-shell",
            environmentProfile: .shell,
            coordinator: coordinator
        )
        let controller = ShellChannelController(
            id: channelID,
            instanceNumber: nil,
            label: "broker-shell",
            workingDirectory: "/tmp",
            terminal: terminal,
            brokerSessionCoordinator: nil
        )

        controller.activate()
        defer {
            if let id = controller.brokerSessionID { _ = try? coordinator.markErrored(id) }
        }

        let running = try registry.load().single()
        XCTAssertEqual(running.id, controller.brokerSessionID)
        XCTAssertEqual(running.label, "broker-shell")
        XCTAssertEqual(running.command, "/bin/zsh")
        XCTAssertEqual(running.lifecycle, .running)
        XCTAssertEqual(running.lastAttachedChannelID, channelID)
        XCTAssertEqual(try registry.load().count, 1)

        controller.deactivate()

        let detached = try registry.load().single()
        XCTAssertEqual(detached.id, running.id)
        XCTAssertEqual(detached.lifecycle, .detached)
        XCTAssertNil(detached.lastAttachedChannelID)
    }

    func testActivationDoesNotMarkChannelActiveWhenTerminalStartFails() {
        let terminal = MockTerminalProcess()
        terminal.startFailureDescription = "broker unavailable"
        let delegate = MockChannelDelegate()
        let controller = ShellChannelController(id: UUID(), instanceNumber: nil, terminal: terminal)
        controller.delegate = delegate

        controller.activate()

        XCTAssertTrue(terminal.startProcessCalled)
        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertEqual(controller.recoveryAction, .reconnect)
        XCTAssertEqual(delegate.stateChanges, [.connecting, .disconnected])
    }

    func testActivationMarksChannelStaleWhenRestoredBrokerSessionIsMissing() {
        let terminal = MockTerminalProcess()
        terminal.startFailureDescription = "missing broker session"
        terminal.startFailureKind = .brokerSessionStale
        let delegate = MockChannelDelegate()
        let controller = ShellChannelController(id: UUID(), instanceNumber: nil, terminal: terminal)
        controller.delegate = delegate

        controller.activate()

        XCTAssertEqual(controller.state, .stale)
        XCTAssertEqual(controller.recoveryAction, .recreateBrokerSession)
        XCTAssertEqual(delegate.stateChanges, [.connecting, .stale])
    }

    func testActivationPreservesBrokerSessionIDWhenBrokerHostIsUnavailable() {
        let preservedID = BrokerSessionID(rawValue: "shell-host-unavailable-session")
        let terminal = MockTerminalProcess()
        terminal.brokerOwnedSessionID = preservedID
        terminal.startFailureDescription = "broker host unavailable"
        terminal.startFailureKind = .brokerHostUnavailable
        let delegate = MockChannelDelegate()
        let controller = ShellChannelController(id: UUID(), instanceNumber: nil, terminal: terminal)
        controller.delegate = delegate

        controller.activate()

        XCTAssertEqual(controller.state, .stale)
        XCTAssertEqual(controller.brokerSessionID, preservedID)
        XCTAssertEqual(controller.recoveryAction, .retryBrokerHost)
        XCTAssertEqual(delegate.stateChanges, [.connecting, .stale])
    }

    /// A running tab whose broker host disappears must downgrade to an explicit
    /// retryable stale state, keep the session handle for retry, and stop
    /// accepting input — not trap inside an output poll or a keystroke.
    func testLiveTabDowngradesToRetryableStaleWhenBrokerHostDisappears() {
        let preservedID = BrokerSessionID(rawValue: "shell-live-host-loss-session")
        let terminal = MockTerminalProcess()
        let delegate = MockChannelDelegate()
        let controller = ShellChannelController(id: UUID(), instanceNumber: nil, terminal: terminal)
        controller.delegate = delegate
        controller.activate()
        XCTAssertEqual(controller.state, .active)

        terminal.brokerOwnedSessionID = preservedID
        terminal.reportSessionFailure(kind: .brokerHostUnavailable)

        XCTAssertEqual(controller.state, .stale)
        XCTAssertEqual(controller.brokerSessionID, preservedID, "A host outage must keep the handle so retry reattaches the same session")
        XCTAssertNil(controller.staleBrokerSessionID)
        XCTAssertEqual(controller.recoveryAction, .retryBrokerHost)
        XCTAssertEqual(delegate.stateChanges, [.connecting, .active, .stale])

        // Repeated reports and late keystrokes must not churn the tab or write
        // input into a session that is known to be unreachable.
        terminal.reportSessionFailure(kind: .brokerHostUnavailable)
        controller.sendInput("echo still-here")
        XCTAssertEqual(delegate.stateChanges, [.connecting, .active, .stale])
        XCTAssertTrue(terminal.sentBytes.isEmpty, "A downgraded tab must not forward input into a lost session")
    }

    func testActivationRetainsStaleBrokerIdentityWhenRestoredSessionIsMissing() {
        let deadID = BrokerSessionID(rawValue: "shell-stale-restored-session")
        let terminal = MockTerminalProcess()
        terminal.staleBrokerSessionID = deadID
        terminal.startFailureDescription = "missing broker session"
        terminal.startFailureKind = .brokerSessionStale
        let controller = ShellChannelController(id: UUID(), instanceNumber: nil, terminal: terminal)

        controller.activate()

        XCTAssertEqual(controller.state, .stale)
        XCTAssertNil(controller.brokerSessionID, "A stale tab must not keep a live broker handle to reattach")
        XCTAssertEqual(controller.staleBrokerSessionID, deadID, "Stale identity must survive so guidance persists across relaunch")
        XCTAssertEqual(controller.recoveryAction, .recreateBrokerSession)
    }

    func testRestoredStaleTabReportsRecreateGuidanceWithoutStartingAProcess() {
        let deadID = BrokerSessionID(rawValue: "shell-restored-stale-session")
        let terminal = MockTerminalProcess()
        let controller = ShellChannelController(
            id: UUID(),
            instanceNumber: nil,
            label: "holoscape",
            workingDirectory: "/tmp/restored-stale",
            terminal: terminal,
            restoredStaleBrokerSessionID: deadID
        )

        XCTAssertEqual(controller.state, .stale)
        XCTAssertEqual(controller.staleBrokerSessionID, deadID)
        XCTAssertEqual(controller.recoveryAction, .recreateBrokerSession)
        XCTAssertFalse(
            terminal.startProcessCalled,
            "Restoring a stale tab must not spawn a replacement the user did not ask for"
        )
    }

    func testRecoveryFromRestoredStaleTabStartsReplacementAndClearsStaleIdentity() {
        let deadID = BrokerSessionID(rawValue: "shell-restored-stale-session")
        let replacementID = BrokerSessionID(rawValue: "shell-replacement-session")
        let terminal = MockTerminalProcess()
        let controller = ShellChannelController(
            id: UUID(),
            instanceNumber: nil,
            terminal: terminal,
            restoredStaleBrokerSessionID: deadID
        )
        terminal.brokerOwnedSessionID = replacementID

        controller.retry()

        XCTAssertEqual(controller.state, .active)
        XCTAssertEqual(controller.brokerSessionID, replacementID)
        XCTAssertNil(controller.staleBrokerSessionID)
        XCTAssertNil(controller.recoveryAction)
    }

    func testGenericShellLabelUsesDirectoryName() {
        let controller = ShellChannelController(
            id: UUID(),
            instanceNumber: nil,
            label: "Shell",
            workingDirectory: "/Users/test/projects/holoscape"
        )

        XCTAssertEqual(controller.displayLabel, "holoscape")
    }

    func testCustomShellLabelIsPreserved() {
        let controller = ShellChannelController(
            id: UUID(),
            instanceNumber: nil,
            label: "logs",
            workingDirectory: "/Users/test/projects/holoscape"
        )

        XCTAssertEqual(controller.displayLabel, "logs")
    }
}

private extension Array {
    func single(file: StaticString = #filePath, line: UInt = #line) throws -> Element {
        XCTAssertEqual(count, 1, file: file, line: line)
        return self[0]
    }
}
