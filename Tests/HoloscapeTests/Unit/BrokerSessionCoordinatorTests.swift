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
        var running = false
        var observedTerminationStatus: Int32? = 0

        func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {
            if let createError { throw createError }
            events.append(.create(id, request))
        }

        func detachSession(id: BrokerSessionID) throws {
            events.append(.detach(id))
        }

        func attachSession(id: BrokerSessionID, channelID: UUID) throws {
            events.append(.attach(id, channelID))
        }

        func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {
            events.append(.terminate(id, exitCode))
        }

        func markSessionErrored(id: BrokerSessionID) throws {
            events.append(.markErrored(id))
        }

        func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(id: BrokerSessionID) throws -> Data { Data() }
        func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(id: BrokerSessionID) throws -> Bool { running }
        func terminationStatus(id: BrokerSessionID) throws -> Int32? { observedTerminationStatus }
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

    private func makeCoordinator(
        runtime: any BrokerSessionRuntime = MetadataOnlyBrokerSessionRuntime(),
        now: @escaping () -> Date
    ) -> BrokerSessionCoordinator {
        BrokerSessionCoordinator(
            registry: BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json")),
            runtime: runtime,
            now: now
        )
    }
}
