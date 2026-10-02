import XCTest
@testable import Holoscape

final class BrokerSessionCoordinatorTests: XCTestCase {
    private enum RuntimeError: Error, Equatable {
        case failed
    }

    private final class RecordingBrokerSessionRuntime: BrokerSessionRuntime, BrokerSessionAgentStatusOwnerTokenAcknowledgingRuntime {
        enum Event: Equatable {
            case create(BrokerSessionID, BrokerSessionLaunchRequest)
            case detach(BrokerSessionID)
            case attach(BrokerSessionID, UUID)
            case terminate(BrokerSessionID, Int32?)
            case markErrored(BrokerSessionID)
            case resize(BrokerSessionID, TerminalGridSize)
        }

        var events: [Event] = []
        var createError: Error?
        var attachError: Error?
        var onAttach: (() throws -> Void)?
        var terminateError: Error?
        var onTerminate: (() throws -> Void)?
        var markErroredError: Error?
        var onMarkErrored: (() throws -> Void)?
        var statusError: Error?
        var running = false
        var observedTerminationStatus: Int32? = 0
        var statusCalledOnMainActor = false
        var scrollbackOutput = Data("reattach scrollback tail".utf8)
        var listedSessionIDs: [BrokerSessionID] = []

        func listSessions() throws -> [BrokerSessionID] { listedSessionIDs }

        func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {
            if let createError { throw createError }
            events.append(.create(id, request))
        }

        func createSessionAcknowledgingAgentStatusOwnerToken(
            id: BrokerSessionID,
            request: BrokerSessionLaunchRequest
        ) throws -> Bool {
            try createSession(id: id, request: request)
            return request.agentStatusOwnerToken != nil
        }

        func detachSession(id: BrokerSessionID) throws {
            events.append(.detach(id))
        }

        func attachSession(id: BrokerSessionID, channelID: UUID) throws {
            if let attachError { throw attachError }
            events.append(.attach(id, channelID))
            try onAttach?()
        }

        func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {
            events.append(.terminate(id, exitCode))
            try onTerminate?()
            if let terminateError { throw terminateError }
        }

        func markSessionErrored(id: BrokerSessionID) throws {
            events.append(.markErrored(id))
            try onMarkErrored?()
            if let markErroredError { throw markErroredError }
        }

        func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(id: BrokerSessionID) throws -> Data { Data() }
        func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data {
            maxBytes > 0 ? Data(scrollbackOutput.suffix(maxBytes)) : Data()
        }
        func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {
            events.append(.resize(id, size))
        }
        func isRunning(id: BrokerSessionID) throws -> Bool {
            statusCalledOnMainActor = Thread.isMainThread
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

    func testUpdateWorkingDirectoryPreservesSessionIdentityAndSkipsDuplicateWrites() throws {
        var now = Date(timeIntervalSince1970: 10)
        let coordinator = makeCoordinator(now: { now })
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let started = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/bin/zsh",
                arguments: ["--login"],
                workingDirectory: "/Users/test/project",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 120, rows: 40)
            ),
            channelType: .shell,
            label: "project",
            attachedChannelID: channelID
        )

        now = Date(timeIntervalSince1970: 20)
        let updated = try coordinator.updateWorkingDirectory(started.id, to: "/Users/test/project/subdir")

        XCTAssertEqual(updated.workingDirectory, "/Users/test/project/subdir")
        XCTAssertEqual(updated.updatedAt, now)
        XCTAssertEqual(updated.id, started.id)
        XCTAssertEqual(updated.channelType, started.channelType)
        XCTAssertEqual(updated.label, started.label)
        XCTAssertEqual(updated.command, started.command)
        XCTAssertEqual(updated.arguments, started.arguments)
        XCTAssertEqual(updated.environmentProfile, started.environmentProfile)
        XCTAssertEqual(updated.agentStatusOwnerToken, started.agentStatusOwnerToken)
        XCTAssertEqual(updated.lifecycle, started.lifecycle)
        XCTAssertEqual(updated.lastAttachedChannelID, started.lastAttachedChannelID)

        now = Date(timeIntervalSince1970: 30)
        let duplicate = try coordinator.updateWorkingDirectory(started.id, to: "/Users/test/project/subdir")

        XCTAssertEqual(duplicate, updated, "An unchanged cwd must not rewrite updatedAt")
        XCTAssertEqual(try coordinator.loadAll(), [updated])
    }

    func testLegacyBrokerCreateResponseDoesNotPersistUnappliedOwnerToken() throws {
        let codec = BrokerSessionHostCodec()
        let runtime = BrokerSessionHostClientRuntime(startsOutputAvailabilityMonitor: false) { frame in
            guard case .create = try codec.decodeRequest(frame) else {
                return try codec.encodeResponse(
                    .failure(BrokerSessionHostFailure(code: "unexpected", message: "Expected create"))
                )
            }
            // A pre-capability durable broker ignores the additive launch field
            // and returns its legacy success response.
            return try codec.encodeResponse(.ok)
        }
        let coordinator = BrokerSessionCoordinator(
            registry: BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("legacy-host-sessions.json")),
            runtime: runtime,
            now: { Date(timeIntervalSince1970: 1_800_000_001) }
        )
        let request = BrokerSessionLaunchRequest(
            command: "/usr/bin/env",
            arguments: ["codex"],
            workingDirectory: "/tmp",
            environmentProfile: .agentOAuth,
            agentStatusOwnerToken: "new-app-owner-token",
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        let record = try coordinator.start(
            request,
            channelType: .agentDirect,
            label: "Codex",
            attachedChannelID: UUID()
        )

        XCTAssertNil(record.agentStatusOwnerToken, "Legacy host success must not claim an owner token it did not inject")
        let persisted = try XCTUnwrap(coordinator.loadAll().first)
        XCTAssertNil(persisted.agentStatusOwnerToken)
    }

    func testDetachPreservesDurableRetirementIntentDuringTeardown() throws {
        let runtime = RecordingBrokerSessionRuntime()
        let coordinator = makeCoordinator(runtime: runtime, now: { Date(timeIntervalSince1970: 42) })
        let started = try coordinator.start(
            launchRequest(workingDirectory: "/tmp/retiring"),
            channelType: .shell,
            label: "retiring",
            attachedChannelID: nil
        )
        var teardownRecord: BrokerSessionRecord?
        runtime.onMarkErrored = {
            // Force teardown to run after `.terminating` is durable but before
            // retirement's runtime RPC completes—the exact race that previously
            // rewrote the record to `.detached`.
            teardownRecord = try coordinator.detach(started.id)
        }

        let errored = try coordinator.markErrored(started.id)

        XCTAssertEqual(teardownRecord?.lifecycle, .terminating)
        XCTAssertEqual(errored.lifecycle, .errored)
        XCTAssertEqual(try coordinator.loadAll().first?.lifecycle, .errored)
        XCTAssertFalse(runtime.events.contains(.detach(started.id)))
    }

    func testDetachAndReattachUpdateLifecycleWithoutChangingLaunchIntent() throws {
        var now = Date(timeIntervalSince1970: 10)
        let runtime = RecordingBrokerSessionRuntime()
        let coordinator = makeCoordinator(runtime: runtime, now: { now })
        let firstChannel = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondChannel = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let request = BrokerSessionLaunchRequest(
            command: "/usr/bin/env",
            arguments: ["codex"],
            workingDirectory: nil,
            environmentProfile: .agentOAuth,
            agentStatusOwnerToken: "reattached-owner-token",
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
        XCTAssertEqual(detached.agentStatusOwnerToken, "reattached-owner-token")
        XCTAssertEqual(detached.createdAt, started.createdAt)
        XCTAssertEqual(detached.updatedAt, now)

        now = Date(timeIntervalSince1970: 30)
        let reattached = try coordinator.reattach(started.id, attachedChannelID: secondChannel)

        XCTAssertEqual(reattached.lifecycle, .running)
        XCTAssertEqual(reattached.lastAttachedChannelID, secondChannel)
        XCTAssertEqual(reattached.agentStatusOwnerToken, "reattached-owner-token")
        XCTAssertEqual(reattached.createdAt, started.createdAt)
        XCTAssertEqual(reattached.updatedAt, now)
    }

    func testDetachDuringReattachCannotRepublishDurableOwnership() throws {
        let runtime = RecordingBrokerSessionRuntime()
        var coordinator: BrokerSessionCoordinator!
        coordinator = makeCoordinator(runtime: runtime, now: { Date(timeIntervalSince1970: 40) })
        let started = try coordinator.start(
            launchRequest(workingDirectory: "/tmp/reattach-detach-race"),
            channelType: .shell,
            label: "race",
            attachedChannelID: UUID(uuidString: "00000000-0000-0000-0000-000000000040")!
        )
        _ = try coordinator.detach(started.id)
        runtime.onAttach = {
            _ = try coordinator.detach(started.id)
        }

        XCTAssertThrowsError(
            try coordinator.reattach(
                started.id,
                attachedChannelID: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
            )
        ) { error in
            XCTAssertEqual(
                error as? BrokerSessionCoordinator.CoordinatorError,
                .concurrentSessionTransition(started.id)
            )
        }

        let durable = try XCTUnwrap(coordinator.loadAll().first)
        XCTAssertEqual(durable.lifecycle, .detached)
        XCTAssertNil(durable.lastAttachedChannelID)
        XCTAssertEqual(
            runtime.events.filter { $0 == .detach(started.id) }.count,
            3,
            "The lost reattach lease must issue a final runtime detach after the racing teardown"
        )
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
        XCTAssertThrowsError(try coordinator.reattach(record.id, attachedChannelID: UUID())) { error in
            XCTAssertEqual(
                error as? BrokerSessionCoordinator.CoordinatorError,
                .staleSession(record.id)
            )
        }
        XCTAssertEqual(try coordinator.reconcileRuntimeStatus(record.id), exited)
    }

    func testExitRebasesFinalStateAfterConcurrentMetadataUpdate() throws {
        var now = Date(timeIntervalSince1970: 110)
        let runtime = RecordingBrokerSessionRuntime()
        let coordinator = makeCoordinator(runtime: runtime, now: { now })
        let record = try coordinator.start(
            launchRequest(workingDirectory: "/tmp/before-exit"),
            channelType: .shell,
            label: nil,
            attachedChannelID: nil
        )
        runtime.onTerminate = {
            now = Date(timeIntervalSince1970: 111)
            _ = try coordinator.updateWorkingDirectory(record.id, to: "/tmp/final-directory")
        }

        now = Date(timeIntervalSince1970: 112)
        let exited = try coordinator.exit(record.id, exitCode: 7)

        XCTAssertEqual(exited.lifecycle, .exited)
        XCTAssertEqual(exited.exitCode, 7)
        XCTAssertEqual(exited.workingDirectory, "/tmp/final-directory")
        XCTAssertEqual(try coordinator.loadAll(), [exited])
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

    func testMarkErroredKeepsTerminatingStateWhenBrokerResponseIsLost() throws {
        let runtime = RecordingBrokerSessionRuntime()
        let coordinator = makeCoordinator(runtime: runtime, now: { Date(timeIntervalSince1970: 202) })
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
        runtime.markErroredError = BrokerSessionHostClientRuntime.ClientError.transportFailed("response lost")

        XCTAssertThrowsError(try coordinator.markErrored(record.id)) { error in
            guard case BrokerSessionHostClientRuntime.ClientError.transportFailed = error else {
                return XCTFail("Expected ambiguous transport failure, got \(error)")
            }
        }

        XCTAssertEqual(
            try XCTUnwrap(coordinator.loadAll().first).lifecycle,
            .terminating,
            "A lost broker response must not restore durable state to running after retirement may have completed"
        )

        runtime.markErroredError = nil
        XCTAssertEqual(try coordinator.markErrored(record.id).lifecycle, .errored)
    }

    func testRelaunchDiscoveryIsDispatchedOffMainActor() async throws {
        let runtime = RecordingBrokerSessionRuntime()
        runtime.running = true
        let coordinator = makeCoordinator(runtime: runtime, now: { Date(timeIntervalSince1970: 700) })
        _ = try coordinator.start(
            launchRequest(workingDirectory: "/tmp/off-main"),
            channelType: .shell,
            label: "off-main",
            attachedChannelID: nil
        )
        let recovery = BrokerRecoveryCoordinator(coordinator)

        let sessions = try await withCheckedThrowingContinuation { continuation in
            recovery.load { result in
                continuation.resume(with: result)
            }
        }

        XCTAssertEqual(sessions.count, 1)
        XCTAssertFalse(runtime.statusCalledOnMainActor)
    }

    func testRelaunchDiscoveryFinishesPendingRetirementBeforeAllowingReplacement() throws {
        let runtime = RecordingBrokerSessionRuntime()
        let coordinator = makeCoordinator(runtime: runtime, now: { Date(timeIntervalSince1970: 203.75) })
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
        runtime.markErroredError = BrokerSessionHostClientRuntime.ClientError.transportFailed("request delivery unknown")
        XCTAssertThrowsError(try coordinator.markErrored(record.id))
        XCTAssertEqual(try XCTUnwrap(coordinator.loadAll().first).lifecycle, .terminating)

        runtime.markErroredError = nil
        XCTAssertEqual(try coordinator.reattachableSessions(), [])
        XCTAssertEqual(try XCTUnwrap(coordinator.loadAll().first).lifecycle, .errored)
        XCTAssertEqual(
            runtime.events.filter { event in
                if case .markErrored(record.id) = event { return true }
                return false
            }.count,
            2,
            "Relaunch discovery must retry the old generation's retirement before replacement"
        )
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
    func testStartRemovesRuntimeSessionWhenRegistryWriteFails() throws {
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
            [.create(createdID, request), .markErrored(createdID)],
            "A start whose registry write fails must remove the session it just created"
        )
        XCTAssertEqual(try registry.load(), [], "A rolled-back start must not persist a record")
    }

    /// #7377 — when rollback fails, the typed error preserves both the registry
    /// failure and the runtime identity required for a safe retry.
    func testStartRollbackFailureSurfacesUntrackedIdentityAndRegistryFailure() throws {
        let runtime = RecordingBrokerSessionRuntime()
        runtime.markErroredError = RuntimeError.failed
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
            guard case let BrokerSessionCoordinator.CoordinatorError.untrackedSession(id, registryFailure, rollbackFailure) = error else {
                return XCTFail("Expected typed untracked-session failure, got \(error)")
            }
            XCTAssertEqual(rollbackFailure, "failed")
            XCTAssertFalse(registryFailure.isEmpty)
            guard case let .create(createdID, _) = runtime.events.first else { return XCTFail("Missing create") }
            XCTAssertEqual(id, createdID)
        }

        guard case let .create(createdID, _) = runtime.events.first else {
            return XCTFail("Expected the runtime session to be created: \(runtime.events)")
        }
        XCTAssertEqual(
            runtime.events,
            [.create(createdID, request), .markErrored(createdID)],
            "The rollback must still be attempted when it is going to fail"
        )

        runtime.markErroredError = nil
        try coordinator.retireUntrackedSession(createdID)
        XCTAssertEqual(
            runtime.events,
            [.create(createdID, request), .markErrored(createdID), .markErrored(createdID)],
            "Retry must retire the known untracked generation before any replacement can start"
        )
    }

    func testStartWithLostCreateResponseRetiresGeneratedIdentityBeforeReportingHostFailure() throws {
        let runtime = RecordingBrokerSessionRuntime()
        runtime.createError = BrokerSessionHostClientRuntime.ClientError.transportFailed("response lost")
        let coordinator = makeCoordinator(runtime: runtime, now: { Date(timeIntervalSince1970: 601) })

        XCTAssertThrowsError(
            try coordinator.start(
                launchRequest(workingDirectory: "/tmp/uncertain-create"),
                channelType: .shell,
                label: "uncertain",
                attachedChannelID: nil
            )
        ) { error in
            guard case let BrokerSessionCoordinator.CoordinatorError.brokerHostUnavailable(id, message) = error else {
                return XCTFail("Expected typed broker-host failure, got \(error)")
            }
            XCTAssertEqual(message, "response lost")
            XCTAssertEqual(runtime.events, [.markErrored(id)])
        }
    }

    func testStartWithUnexpectedCreateResponseRetiresGeneratedIdentityBeforeReportingHostFailure() throws {
        let runtime = RecordingBrokerSessionRuntime()
        runtime.createError = BrokerSessionHostClientRuntime.ClientError.unexpectedResponse(
            expected: "created",
            actual: .ok
        )
        let coordinator = makeCoordinator(runtime: runtime, now: { Date(timeIntervalSince1970: 603) })

        XCTAssertThrowsError(
            try coordinator.start(
                launchRequest(workingDirectory: "/tmp/unexpected-create-response"),
                channelType: .shell,
                label: "unexpected",
                attachedChannelID: nil
            )
        ) { error in
            guard case let BrokerSessionCoordinator.CoordinatorError.brokerHostUnavailable(id, message) = error else {
                return XCTFail("Expected typed broker-host failure, got \(error)")
            }
            XCTAssertTrue(message.contains("unexpected response"))
            XCTAssertEqual(runtime.events, [.markErrored(id)])
        }
    }

    func testStartWithLostCreateResponsePreservesIdentityWhenRetirementIsUncertain() throws {
        let runtime = RecordingBrokerSessionRuntime()
        runtime.createError = BrokerSessionHostClientRuntime.ClientError.transportFailed("response lost")
        runtime.markErroredError = RuntimeError.failed
        let coordinator = makeCoordinator(runtime: runtime, now: { Date(timeIntervalSince1970: 602) })

        XCTAssertThrowsError(
            try coordinator.start(
                launchRequest(workingDirectory: "/tmp/uncertain-create-retirement"),
                channelType: .shell,
                label: "uncertain",
                attachedChannelID: nil
            )
        ) { error in
            guard case let BrokerSessionCoordinator.CoordinatorError.untrackedSession(id, registryFailure, rollbackFailure) = error else {
                return XCTFail("Expected typed untracked-session failure, got \(error)")
            }
            XCTAssertTrue(registryFailure.contains("response lost"))
            XCTAssertEqual(rollbackFailure, "failed")
            XCTAssertEqual(runtime.events, [.markErrored(id)])
        }
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

    func testRelaunchDiscoveryRevokesAbandonedReattachLease() throws {
        let runtime = RecordingBrokerSessionRuntime()
        runtime.running = true
        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("reattach-lease.json"))
        let coordinator = makeCoordinator(runtime: runtime, registry: registry, now: { Date(timeIntervalSince1970: 525) })
        let started = try coordinator.start(
            launchRequest(workingDirectory: "/tmp/reattach-lease"),
            channelType: .shell,
            label: "lease",
            attachedChannelID: UUID()
        )
        let lease = BrokerSessionRecord(
            id: started.id,
            channelType: started.channelType,
            label: started.label,
            command: started.command,
            arguments: started.arguments,
            workingDirectory: started.workingDirectory,
            environmentProfile: started.environmentProfile,
            agentStatusOwnerToken: started.agentStatusOwnerToken,
            lifecycle: .reattaching,
            exitCode: nil,
            createdAt: started.createdAt,
            updatedAt: Date(timeIntervalSince1970: 524),
            lastAttachedChannelID: nil
        )
        try registry.upsert(lease)

        let discovered = try coordinator.reattachableSessions()

        XCTAssertEqual(discovered.count, 1)
        XCTAssertEqual(discovered[0].id, started.id)
        XCTAssertEqual(discovered[0].lifecycle, .detached)
        XCTAssertNil(discovered[0].lastAttachedChannelID)
        XCTAssertEqual(try registry.load(), discovered)
    }

    func testRelaunchDiscoveryRetiresRuntimeSessionsMissingFromRegistry() throws {
        let runtime = RecordingBrokerSessionRuntime()
        let orphan = BrokerSessionID(rawValue: "failed-start-orphan")
        runtime.listedSessionIDs = [orphan]
        let coordinator = makeCoordinator(runtime: runtime, now: Date.init)

        XCTAssertEqual(try coordinator.reattachableSessions(), [])
        XCTAssertEqual(runtime.events, [.markErrored(orphan)])
    }

    func testReattachRevokesRuntimeOwnershipWhenRegistryFailsAfterAttach() throws {
        let runtime = RecordingBrokerSessionRuntime()
        runtime.running = true
        let registryURL = tempDirectory.appendingPathComponent("reattach-registry-failure.json")
        let registry = BrokerSessionRegistry(fileURL: registryURL)
        let coordinator = makeCoordinator(runtime: runtime, registry: registry, now: Date.init)
        let started = try coordinator.start(
            launchRequest(workingDirectory: "/tmp/reattach-registry-failure"),
            channelType: .shell,
            label: "registry-failure",
            attachedChannelID: UUID()
        )
        runtime.events.removeAll()
        runtime.onAttach = {
            try FileManager.default.removeItem(at: registryURL)
            try FileManager.default.createDirectory(at: registryURL, withIntermediateDirectories: false)
        }

        XCTAssertThrowsError(try coordinator.reattach(started.id, attachedChannelID: UUID())) { error in
            guard case BrokerSessionCoordinator.CoordinatorError.reattachRollbackFailed = error else {
                return XCTFail("Expected typed reattach rollback failure, got \(error)")
            }
        }
        XCTAssertEqual(runtime.events.count, 2)
        guard case .attach(started.id, _) = runtime.events[0] else {
            return XCTFail("Expected attach before registry failure: \(runtime.events)")
        }
        XCTAssertEqual(runtime.events[1], .detach(started.id))
    }

    func testResizeForwardsExactGridSizeToRuntimeWithoutMutatingRecord() throws {
        let runtime = RecordingBrokerSessionRuntime()
        let coordinator = makeCoordinator(runtime: runtime, now: { Date(timeIntervalSince1970: 550) })
        let request = BrokerSessionLaunchRequest(
            command: "/bin/zsh",
            workingDirectory: "/tmp/resize-truth",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        let started = try coordinator.start(
            request,
            channelType: .shell,
            label: nil,
            attachedChannelID: UUID(uuidString: "00000000-0000-0000-0000-000000000550")!
        )

        let size = TerminalGridSize(columns: 132, rows: 48)
        try coordinator.resize(started.id, size: size)

        XCTAssertEqual(runtime.events, [.create(started.id, request), .resize(started.id, size)])
        XCTAssertEqual(
            try coordinator.loadAll(),
            [started],
            "Resize must propagate to the PTY without mutating durable lifecycle metadata"
        )
    }

    func testResizeMissingSessionFailsLoudlyWithoutTouchingRuntime() throws {
        let runtime = RecordingBrokerSessionRuntime()
        let coordinator = makeCoordinator(runtime: runtime, now: { Date(timeIntervalSince1970: 1) })
        let missingID = BrokerSessionID(rawValue: "missing-resize-session")

        XCTAssertThrowsError(
            try coordinator.resize(missingID, size: TerminalGridSize(columns: 100, rows: 30))
        ) { error in
            XCTAssertEqual(error as? BrokerSessionCoordinator.CoordinatorError, .missingSession(missingID))
        }
        XCTAssertEqual(runtime.events, [])
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

    func testReconcileRuntimeStatusRetiresScrollbackPersistenceFailureAndMarksErrored() throws {
        let runtime = RecordingBrokerSessionRuntime()
        var now = Date(timeIntervalSince1970: 780)
        let coordinator = makeCoordinator(runtime: runtime, now: { now })
        let started = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/bin/zsh",
                workingDirectory: "/tmp/failed-scrollback-runtime",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .shell,
            label: "failed-scrollback-runtime",
            attachedChannelID: UUID(uuidString: "00000000-0000-0000-0000-000000000780")!
        )

        now = Date(timeIntervalSince1970: 781)
        runtime.statusError = NativePTYBrokerSessionRuntime.RuntimeError.scrollbackPersistenceFailed(
            started.id,
            reason: "disk full"
        )
        let reconciled = try coordinator.reconcileRuntimeStatus(started.id)

        XCTAssertEqual(reconciled.lifecycle, .errored)
        XCTAssertNil(reconciled.exitCode)
        XCTAssertNil(reconciled.lastAttachedChannelID)
        XCTAssertEqual(reconciled.updatedAt, now)
        XCTAssertTrue(runtime.events.contains(.markErrored(started.id)))
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
