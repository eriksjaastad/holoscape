import XCTest
@testable import Holoscape

final class BrokerSessionCoordinatorTests: XCTestCase {
    private enum RuntimeError: Error, Equatable {
        case failed
    }

    private final class RecordingBrokerSessionRuntime: BrokerSessionRuntime {
        enum Event: Equatable {
            case create(BrokerSessionID, BrokerSessionLaunchRequest)
            case detach(BrokerSessionID)
            case attach(BrokerSessionID, UUID)
            case terminate(BrokerSessionID, Int32?)
            case markErrored(BrokerSessionID)
        }

        var events: [Event] = []
        var createError: Error?
        var attachError: Error?
        var terminateError: Error?
        var statusError: Error?
        var running = false
        var observedTerminationStatus: Int32? = 0
        var scrollbackOutput = Data("reattach scrollback tail".utf8)

        func listSessions() throws -> [BrokerSessionID] { [] }

        func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {
            if let createError { throw createError }
            events.append(.create(id, request))
        }

        func detachSession(id: BrokerSessionID) throws {
            events.append(.detach(id))
        }

        func attachSession(id: BrokerSessionID, channelID: UUID) throws {
            if let attachError { throw attachError }
            events.append(.attach(id, channelID))
        }

        func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {
            events.append(.terminate(id, exitCode))
            if let terminateError { throw terminateError }
        }

        func markSessionErrored(id: BrokerSessionID) throws {
            events.append(.markErrored(id))
        }

        func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(id: BrokerSessionID) throws -> Data { Data() }
        func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data {
            maxBytes > 0 ? Data(scrollbackOutput.suffix(maxBytes)) : Data()
        }
        func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(id: BrokerSessionID) throws -> Bool {
            if let statusError { throw statusError }
            return running
        }
        func terminationStatus(id: BrokerSessionID) throws -> Int32? {
            if let statusError { throw statusError }
            return observedTerminationStatus
        }
    }

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerSessionCoordinatorTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testStartCreatesDurableRunningRecordFromSafeLaunchRequest() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinator = makeCoordinator(now: { now })
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let request = BrokerSessionLaunchRequest(
            command: "/bin/zsh",
            arguments: ["--login"],
            workingDirectory: "/Users/test/project",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 120, rows: 40)
        )

        let record = try coordinator.start(
            request,
            channelType: .shell,
            label: "project",
            attachedChannelID: channelID
        )

        XCTAssertEqual(record.channelType, .shell)
        XCTAssertEqual(record.label, "project")
        XCTAssertEqual(record.command, "/bin/zsh")
        XCTAssertEqual(record.arguments, ["--login"])
        XCTAssertEqual(record.workingDirectory, "/Users/test/project")
        XCTAssertEqual(record.environmentProfile, .shell)
        XCTAssertEqual(record.lifecycle, .running)
        XCTAssertNil(record.exitCode)
        XCTAssertEqual(record.createdAt, now)
        XCTAssertEqual(record.updatedAt, now)
        XCTAssertEqual(record.lastAttachedChannelID, channelID)
        XCTAssertEqual(try coordinator.loadAll(), [record])
    }

    func testDetachAndReattachUpdateLifecycleWithoutChangingLaunchIntent() throws {
        var now = Date(timeIntervalSince1970: 10)
        let coordinator = makeCoordinator(now: { now })
        let firstChannel = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondChannel = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let request = BrokerSessionLaunchRequest(
            command: "/usr/bin/env",
            arguments: ["codex"],
            workingDirectory: nil,
            environmentProfile: .agentOAuth,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        let started = try coordinator.start(
            request,
            channelType: .agentDirect,
            label: "codex",
            attachedChannelID: firstChannel
        )

        now = Date(timeIntervalSince1970: 20)
        let detached = try coordinator.detach(started.id)

        XCTAssertEqual(detached.lifecycle, .detached)
        XCTAssertNil(detached.lastAttachedChannelID)
        XCTAssertEqual(detached.command, started.command)
        XCTAssertEqual(detached.arguments, started.arguments)
        XCTAssertEqual(detached.environmentProfile, started.environmentProfile)
        XCTAssertEqual(detached.createdAt, started.createdAt)
        XCTAssertEqual(detached.updatedAt, now)

        now = Date(timeIntervalSince1970: 30)
        let reattached = try coordinator.reattach(started.id, attachedChannelID: secondChannel)

        XCTAssertEqual(reattached.lifecycle, .running)
        XCTAssertEqual(reattached.lastAttachedChannelID, secondChannel)
        XCTAssertEqual(reattached.createdAt, started.createdAt)
        XCTAssertEqual(reattached.updatedAt, now)
    }

    func testExitRecordsExitCodeAndRemovesFromReattachableList() throws {
        var now = Date(timeIntervalSince1970: 100)
        let coordinator = makeCoordinator(now: { now })
        let record = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/bin/zsh",
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .shell,
            label: nil,
            attachedChannelID: nil
        )

        XCTAssertEqual(try coordinator.reattachableSessions(), [record])

        now = Date(timeIntervalSince1970: 101)
        let exited = try coordinator.exit(record.id, exitCode: 0)

        XCTAssertEqual(exited.lifecycle, .exited)
        XCTAssertEqual(exited.exitCode, 0)
        XCTAssertEqual(exited.updatedAt, now)
        XCTAssertEqual(try coordinator.reattachableSessions(), [])
    }

    func testMarkErroredRemovesSessionFromReattachableListWithoutInventingExitCode() throws {
        var now = Date(timeIntervalSince1970: 200)
        let coordinator = makeCoordinator(now: { now })
        let record = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/bin/zsh",
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .shell,
            label: nil,
            attachedChannelID: nil
        )

        XCTAssertEqual(try coordinator.reattachableSessions(), [record])

        now = Date(timeIntervalSince1970: 201)
        let errored = try coordinator.markErrored(record.id)

        XCTAssertEqual(errored.lifecycle, .errored)
        XCTAssertNil(errored.exitCode)
        XCTAssertEqual(errored.updatedAt, now)
        XCTAssertEqual(try coordinator.reattachableSessions(), [])
    }

    func testUpdatingMissingSessionFailsLoudly() throws {
        let runtime = RecordingBrokerSessionRuntime()
        let coordinator = makeCoordinator(runtime: runtime, now: { Date(timeIntervalSince1970: 1) })

        XCTAssertThrowsError(try coordinator.detach(BrokerSessionID(rawValue: "missing"))) { error in
            XCTAssertEqual(error as? BrokerSessionCoordinator.CoordinatorError, .missingSession(BrokerSessionID(rawValue: "missing")))
        }
        XCTAssertEqual(runtime.events, [])
    }

    func testStartCreatesRuntimeSessionBeforePersistingMetadata() throws {
        let runtime = RecordingBrokerSessionRuntime()
        let coordinator = makeCoordinator(runtime: runtime, now: { Date(timeIntervalSince1970: 300) })
        let request = BrokerSessionLaunchRequest(
            command: "/bin/zsh",
            arguments: ["--login"],
            workingDirectory: "/tmp/runtime",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 100, rows: 30)
        )

        let record = try coordinator.start(
            request,
            channelType: .shell,
            label: "runtime",
            attachedChannelID: nil
        )

        XCTAssertEqual(runtime.events, [.create(record.id, request)])
        XCTAssertEqual(try coordinator.loadAll(), [record])
    }

    func testRuntimeCreateFailureFailsLoudlyWithoutPersistingMetadata() throws {
        let runtime = RecordingBrokerSessionRuntime()
        runtime.createError = RuntimeError.failed
        let coordinator = makeCoordinator(runtime: runtime, now: { Date(timeIntervalSince1970: 400) })

        XCTAssertThrowsError(try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/bin/zsh",
                workingDirectory: "/tmp/runtime-failure",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .shell,
            label: nil,
            attachedChannelID: nil
        )) { error in
            XCTAssertEqual(error as? RuntimeError, .failed)
        }
        XCTAssertEqual(try coordinator.loadAll(), [])
    }

    /// #7377 — an unrecordable start must not leave an orphaned runtime session.
    func testStartTerminatesRuntimeSessionWhenRegistryWriteFails() throws {
        let runtime = RecordingBrokerSessionRuntime()
        let registry = try makeUnwritableRegistry()
        let coordinator = makeCoordinator(
            runtime: runtime,
            registry: registry,
            now: { Date(timeIntervalSince1970: 500) }
        )
        let request = launchRequest(workingDirectory: "/tmp/unrecordable")

        XCTAssertThrowsError(
            try coordinator.start(request, channelType: .shell, label: "unrecordable", attachedChannelID: nil)
        ) { error in
            // Callers must still see the registry failure, not a rollback artifact.
            XCTAssertFalse(error is BrokerSessionCoordinator.CoordinatorError, "Unexpected coordinator error: \(error)")
        }

        guard case let .create(createdID, _) = runtime.events.first else {
            return XCTFail("Expected the runtime session to be created before the registry write: \(runtime.events)")
        }
        XCTAssertEqual(
            runtime.events,
            [.create(createdID, request), .terminate(createdID, nil)],
            "A start whose registry write fails must terminate the session it just created"
        )
        XCTAssertEqual(try registry.load(), [], "A rolled-back start must not persist a record")
    }

    /// #7377 — when the rollback itself fails, the original registry failure still
    /// surfaces instead of being masked by the cleanup attempt.
    func testStartRollbackFailureStillSurfacesTheRegistryFailure() throws {
        let runtime = RecordingBrokerSessionRuntime()
        runtime.terminateError = RuntimeError.failed
        let registry = try makeUnwritableRegistry()
        let coordinator = makeCoordinator(
            runtime: runtime,
            registry: registry,
            now: { Date(timeIntervalSince1970: 600) }
        )
        let request = launchRequest(workingDirectory: "/tmp/unrecordable-rollback")

        XCTAssertThrowsError(
            try coordinator.start(request, channelType: .shell, label: "unrecordable", attachedChannelID: nil)
        ) { error in
            XCTAssertNotEqual(error as? RuntimeError, .failed, "The rollback failure must not replace the registry failure")
            XCTAssertFalse(error is BrokerSessionCoordinator.CoordinatorError, "Unexpected coordinator error: \(error)")
        }

        guard case let .create(createdID, _) = runtime.events.first else {
            return XCTFail("Expected the runtime session to be created: \(runtime.events)")
        }
        XCTAssertEqual(
            runtime.events,
            [.create(createdID, request), .terminate(createdID, nil)],
            "The rollback must still be attempted when it is going to fail"
        )
    }

    func testReadScrollbackTailRequiresDurableRecordAndUsesRuntimeTail() throws {
        let runtime = RecordingBrokerSessionRuntime()
        let coordinator = makeCoordinator(runtime: runtime, now: { Date(timeIntervalSince1970: 450) })
        let started = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/bin/zsh",
                workingDirectory: "/tmp/scrollback-tail",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .shell,
            label: nil,
            attachedChannelID: nil
        )

        XCTAssertEqual(
            String(decoding: try coordinator.readScrollbackTail(started.id, maxBytes: 15), as: UTF8.self),
            "scrollback tail"
        )
        XCTAssertThrowsError(try coordinator.readScrollbackTail(BrokerSessionID(rawValue: "missing"), maxBytes: 4096)) { error in
            XCTAssertEqual(error as? BrokerSessionCoordinator.CoordinatorError, .missingSession(BrokerSessionID(rawValue: "missing")))
        }
    }

    func testLifecycleTransitionsCallRuntimeFacade() throws {
        let runtime = RecordingBrokerSessionRuntime()
        let firstChannel = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let secondChannel = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let coordinator = makeCoordinator(runtime: runtime, now: { Date(timeIntervalSince1970: 500) })
        let started = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/bin/zsh",
                workingDirectory: "/tmp/runtime-transitions",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .shell,
            label: nil,
            attachedChannelID: firstChannel
        )

        _ = try coordinator.detach(started.id)
        _ = try coordinator.reattach(started.id, attachedChannelID: secondChannel)
        _ = try coordinator.exit(started.id, exitCode: 0)

        XCTAssertEqual(runtime.events, [
            .create(started.id, BrokerSessionLaunchRequest(
                command: "/bin/zsh",
                workingDirectory: "/tmp/runtime-transitions",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            )),
            .detach(started.id),
            .attach(started.id, secondChannel),
            .terminate(started.id, 0)
        ])
    }

    func testReconcileRuntimeStatusPreservesRunningSessions() throws {
        let runtime = RecordingBrokerSessionRuntime()
        runtime.running = true
        let coordinator = makeCoordinator(runtime: runtime, now: { Date(timeIntervalSince1970: 600) })
        let started = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/bin/zsh",
                workingDirectory: "/tmp/runtime-running",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .shell,
            label: "running",
            attachedChannelID: nil
        )

        let reconciled = try coordinator.reconcileRuntimeStatus(started.id)

        XCTAssertEqual(reconciled, started)
        XCTAssertEqual(try coordinator.loadAll(), [started])
    }

    func testReconcileRuntimeStatusRecordsObservedExitCode() throws {
        let runtime = RecordingBrokerSessionRuntime()
        runtime.running = false
        runtime.observedTerminationStatus = 7
        var now = Date(timeIntervalSince1970: 700)
        let coordinator = makeCoordinator(runtime: runtime, now: { now })
        let started = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/bin/sh",
                arguments: ["-c", "exit 7"],
                workingDirectory: "/tmp/runtime-exited",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .shell,
            label: "exited",
            attachedChannelID: UUID(uuidString: "00000000-0000-0000-0000-000000000701")!
        )

        now = Date(timeIntervalSince1970: 701)
        let reconciled = try coordinator.reconcileRuntimeStatus(started.id)

        XCTAssertEqual(reconciled.lifecycle, .exited)
        XCTAssertEqual(reconciled.exitCode, 7)
        XCTAssertNil(reconciled.lastAttachedChannelID)
        XCTAssertEqual(reconciled.updatedAt, now)
        XCTAssertEqual(runtime.events.last, .terminate(started.id, 7))
    }

    func testReattachableSessionsRefreshesRuntimeStatusBeforeReturningCandidates() throws {
        let runtime = RecordingBrokerSessionRuntime()
        runtime.running = false
        runtime.observedTerminationStatus = 9
        var now = Date(timeIntervalSince1970: 750)
        let coordinator = makeCoordinator(runtime: runtime, now: { now })
        let started = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/bin/sh",
                arguments: ["-c", "exit 9"],
                workingDirectory: "/tmp/reattachable-refresh",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .shell,
            label: "finished",
            attachedChannelID: nil
        )

        now = Date(timeIntervalSince1970: 751)
        let reattachable = try coordinator.reattachableSessions()

        XCTAssertEqual(reattachable, [])
        let records = try coordinator.loadAll()
        XCTAssertEqual(records.count, 1)
        let refreshed = records[0]
        XCTAssertEqual(refreshed.id, started.id)
        XCTAssertEqual(refreshed.lifecycle, BrokerSessionLifecycle.exited)
        XCTAssertEqual(refreshed.exitCode, 9)
        XCTAssertEqual(refreshed.updatedAt, now)
    }

    func testReconcileRuntimeStatusMarksMissingRuntimeSessionStaleInsteadOfThrowing() throws {
        let runtime = RecordingBrokerSessionRuntime()
        let missingID = BrokerSessionID(rawValue: "missing-runtime-session")
        runtime.statusError = NativePTYBrokerSessionRuntime.RuntimeError.missingSession(missingID)
        var now = Date(timeIntervalSince1970: 775)
        let coordinator = makeCoordinator(runtime: runtime, now: { now })
        let started = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/bin/zsh",
                workingDirectory: "/tmp/missing-runtime",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .shell,
            label: "stale-runtime",
            attachedChannelID: UUID(uuidString: "00000000-0000-0000-0000-000000000775")!
        )

        now = Date(timeIntervalSince1970: 776)
        runtime.statusError = NativePTYBrokerSessionRuntime.RuntimeError.missingSession(started.id)
        let reconciled = try coordinator.reconcileRuntimeStatus(started.id)

        XCTAssertEqual(reconciled.lifecycle, .stale)
        XCTAssertNil(reconciled.exitCode)
        XCTAssertNil(reconciled.lastAttachedChannelID)
        XCTAssertEqual(reconciled.updatedAt, now)
        XCTAssertEqual(try coordinator.reattachableSessions(), [reconciled])
    }

    func testReconcileRuntimeStatusRequiresTypedHostMissingSessionFailureBeforeMarkingStale() throws {
        let runtime = RecordingBrokerSessionRuntime()
        var now = Date(timeIntervalSince1970: 785)
        let coordinator = makeCoordinator(runtime: runtime, now: { now })
        let started = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/bin/zsh",
                workingDirectory: "/tmp/typed-missing-runtime",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .shell,
            label: "typed-stale-runtime",
            attachedChannelID: UUID(uuidString: "00000000-0000-0000-0000-000000000785")!
        )

        runtime.statusError = BrokerSessionHostClientRuntime.ClientError.hostFailure(
            code: "runtime-error",
            message: "missingSession(\(started.id.rawValue))"
        )
        XCTAssertThrowsError(try coordinator.reconcileRuntimeStatus(started.id)) { error in
            guard case let BrokerSessionHostClientRuntime.ClientError.hostFailure(code, _) = error else {
                return XCTFail("Expected hostFailure, got \(error)")
            }
            XCTAssertEqual(code, "runtime-error")
        }

        now = Date(timeIntervalSince1970: 786)
        runtime.statusError = BrokerSessionHostClientRuntime.ClientError.hostFailure(
            code: "missing-session",
            message: "missingSession(\(started.id.rawValue))"
        )
        let reconciled = try coordinator.reconcileRuntimeStatus(started.id)

        XCTAssertEqual(reconciled.lifecycle, .stale)
        XCTAssertEqual(reconciled.updatedAt, now)
        XCTAssertNil(reconciled.lastAttachedChannelID)
    }

    func testReconcileRuntimeStatusPreservesRecordWhenBrokerHostTransportIsUnavailable() throws {
        let runtime = RecordingBrokerSessionRuntime()
        let coordinator = makeCoordinator(runtime: runtime, now: { Date(timeIntervalSince1970: 790) })
        let started = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/usr/bin/env",
                arguments: ["claude"],
                workingDirectory: "/tmp/host-unavailable-agent",
                environmentProfile: .agentOAuth,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .agentDirect,
            label: "host-unavailable-agent",
            attachedChannelID: UUID(uuidString: "00000000-0000-0000-0000-000000000790")!
        )
        runtime.statusError = BrokerSessionHostClientRuntime.ClientError.transportFailed("socketTimedOut(/tmp/missing.sock)")

        let reconciled = try coordinator.reconcileRuntimeStatus(started.id)

        XCTAssertEqual(reconciled, started)
        XCTAssertEqual(try coordinator.reattachableSessions(), [started])
        XCTAssertEqual(try coordinator.loadAll(), [started])
    }

    func testReattachMissingRuntimeSessionMarksRecordStaleAndFailsLoudly() throws {
        let runtime = RecordingBrokerSessionRuntime()
        var now = Date(timeIntervalSince1970: 792)
        let coordinator = makeCoordinator(runtime: runtime, now: { now })
        let started = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/usr/bin/env",
                arguments: ["codex"],
                workingDirectory: "/tmp/stale-reattach-agent",
                environmentProfile: .agentOAuth,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .agentDirect,
            label: "stale-reattach-agent",
            attachedChannelID: nil
        )
        now = Date(timeIntervalSince1970: 793)
        runtime.attachError = NativePTYBrokerSessionRuntime.RuntimeError.missingSession(started.id)

        XCTAssertThrowsError(try coordinator.reattach(started.id, attachedChannelID: UUID())) { error in
            XCTAssertEqual(error as? BrokerSessionCoordinator.CoordinatorError, .staleSession(started.id))
        }
        let records = try coordinator.loadAll()
        XCTAssertEqual(records.count, 1)
        let stale = records[0]
        XCTAssertEqual(stale.lifecycle, BrokerSessionLifecycle.stale)
        XCTAssertEqual(stale.updatedAt, now)
        XCTAssertNil(stale.lastAttachedChannelID)
    }

    func testReattachBrokerHostTransportFailureDoesNotMutateRecord() throws {
        let runtime = RecordingBrokerSessionRuntime()
        let coordinator = makeCoordinator(runtime: runtime, now: { Date(timeIntervalSince1970: 794) })
        let started = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/usr/bin/env",
                arguments: ["claude"],
                workingDirectory: "/tmp/reattach-host-unavailable",
                environmentProfile: .agentOAuth,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .agentDirect,
            label: "reattach-host-unavailable",
            attachedChannelID: nil
        )
        runtime.attachError = BrokerSessionHostClientRuntime.ClientError.transportFailed("socketTimedOut(/tmp/missing.sock)")

        XCTAssertThrowsError(try coordinator.reattach(started.id, attachedChannelID: UUID())) { error in
            XCTAssertEqual(error as? BrokerSessionCoordinator.CoordinatorError, .brokerHostUnavailable(started.id, "socketTimedOut(/tmp/missing.sock)"))
        }
        XCTAssertEqual(try coordinator.loadAll(), [started])
    }

    func testBrokerHostMissingSessionCodeMarksRecordStaleEvenWithNonSwiftErrorMessage() throws {
        let runtime = RecordingBrokerSessionRuntime()
        var now = Date(timeIntervalSince1970: 795)
        let coordinator = makeCoordinator(runtime: runtime, now: { now })
        let started = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/usr/bin/env",
                arguments: ["codex"],
                workingDirectory: "/tmp/socket-host-missing-agent",
                environmentProfile: .agentOAuth,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .agentDirect,
            label: "socket-host-missing-agent",
            attachedChannelID: nil
        )
        now = Date(timeIntervalSince1970: 796)
        runtime.attachError = BrokerSessionHostClientRuntime.ClientError.hostFailure(
            code: "missing-session",
            message: "session not found: \(started.id.rawValue)"
        )

        XCTAssertThrowsError(try coordinator.reattach(started.id, attachedChannelID: UUID())) { error in
            XCTAssertEqual(error as? BrokerSessionCoordinator.CoordinatorError, .staleSession(started.id))
        }
        let records = try coordinator.loadAll()
        XCTAssertEqual(records.count, 1)
        let stale = records[0]
        XCTAssertEqual(stale.lifecycle, BrokerSessionLifecycle.stale)
        XCTAssertEqual(stale.updatedAt, now)
        XCTAssertNil(stale.lastAttachedChannelID)
    }

    func testReconcileBrokerHostMissingSessionCodeMarksRecordStaleEvenWithNonSwiftErrorMessage() throws {
        let runtime = RecordingBrokerSessionRuntime()
        var now = Date(timeIntervalSince1970: 797)
        let coordinator = makeCoordinator(runtime: runtime, now: { now })
        let started = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/usr/bin/env",
                arguments: ["codex"],
                workingDirectory: "/tmp/socket-host-reconcile-missing-agent",
                environmentProfile: .agentOAuth,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .agentDirect,
            label: "socket-host-reconcile-missing-agent",
            attachedChannelID: UUID(uuidString: "00000000-0000-0000-0000-000000000797")!
        )
        now = Date(timeIntervalSince1970: 798)
        runtime.statusError = BrokerSessionHostClientRuntime.ClientError.hostFailure(
            code: "missing-session",
            message: "session not found: \(started.id.rawValue)"
        )

        let reconciled = try coordinator.reconcileRuntimeStatus(started.id)

        XCTAssertEqual(reconciled.lifecycle, .stale)
        XCTAssertEqual(reconciled.updatedAt, now)
        XCTAssertNil(reconciled.lastAttachedChannelID)
    }

    func testReconcileRuntimeStatusLeavesMetadataOnlyRuntimeUnchanged() throws {
        let coordinator = makeCoordinator(now: { Date(timeIntervalSince1970: 800) })
        let started = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/bin/zsh",
                workingDirectory: "/tmp/metadata-only",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .shell,
            label: "metadata-only",
            attachedChannelID: nil
        )

        let reconciled = try coordinator.reconcileRuntimeStatus(started.id)

        XCTAssertEqual(reconciled, started)
        XCTAssertEqual(try coordinator.loadAll(), [started])
    }

    func testPruneFinalRecordsRemovesOnlyOldExitedAndErroredRecords() throws {
        let runtime = RecordingBrokerSessionRuntime()
        var now = Date(timeIntervalSince1970: 1_000)
        let coordinator = makeCoordinator(runtime: runtime, now: { now })
        let oldExited = try coordinator.start(launchRequest(workingDirectory: "/tmp/old-exited"), channelType: .shell, label: "old-exited", attachedChannelID: nil)
        let oldErrored = try coordinator.start(launchRequest(workingDirectory: "/tmp/old-errored"), channelType: .shell, label: "old-errored", attachedChannelID: nil)
        let oldStale = try coordinator.start(launchRequest(workingDirectory: "/tmp/old-stale"), channelType: .shell, label: "old-stale", attachedChannelID: nil)
        let oldDetached = try coordinator.start(launchRequest(workingDirectory: "/tmp/old-detached"), channelType: .shell, label: "old-detached", attachedChannelID: nil)
        let recentExited = try coordinator.start(launchRequest(workingDirectory: "/tmp/recent-exited"), channelType: .shell, label: "recent-exited", attachedChannelID: nil)

        now = Date(timeIntervalSince1970: 1_010)
        _ = try coordinator.exit(oldExited.id, exitCode: 0)
        _ = try coordinator.markErrored(oldErrored.id)
        _ = try coordinator.detach(oldStale.id)
        now = Date(timeIntervalSince1970: 1_020)
        runtime.statusError = NativePTYBrokerSessionRuntime.RuntimeError.missingSession(oldStale.id)
        _ = try coordinator.reconcileRuntimeStatus(oldStale.id)
        runtime.statusError = nil
        now = Date(timeIntervalSince1970: 1_030)
        _ = try coordinator.detach(oldDetached.id)
        now = Date(timeIntervalSince1970: 1_200)
        _ = try coordinator.exit(recentExited.id, exitCode: 0)

        let removed = try coordinator.pruneFinalRecords(updatedBefore: Date(timeIntervalSince1970: 1_100))

        XCTAssertEqual(removed.map(\.id).sorted { $0.rawValue < $1.rawValue }, [oldErrored.id, oldExited.id].sorted { $0.rawValue < $1.rawValue })
        XCTAssertEqual(
            try coordinator.loadAll().map(\.id).sorted { $0.rawValue < $1.rawValue },
            [oldDetached.id, oldStale.id, recentExited.id].sorted { $0.rawValue < $1.rawValue }
        )
    }

    private func makeCoordinator(
        runtime: any BrokerSessionRuntime = MetadataOnlyBrokerSessionRuntime(),
        registry: BrokerSessionRegistry? = nil,
        now: @escaping () -> Date
    ) -> BrokerSessionCoordinator {
        BrokerSessionCoordinator(
            registry: registry ?? BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json")),
            runtime: runtime,
            now: now
        )
    }

    /// A registry whose reads succeed but whose writes cannot land: the parent
    /// path is an ordinary file, so `createDirectory` fails the way a
    /// permission-denied or unwritable registry location does.
    private func makeUnwritableRegistry() throws -> BrokerSessionRegistry {
        let blocker = tempDirectory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocker)
        return BrokerSessionRegistry(fileURL: blocker.appendingPathComponent("sessions.json"))
    }

    private func launchRequest(workingDirectory: String) -> BrokerSessionLaunchRequest {
        BrokerSessionLaunchRequest(
            command: "/bin/zsh",
            arguments: ["--login"],
            workingDirectory: workingDirectory,
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
    }
}
