import XCTest
@testable import Holoscape

@MainActor
final class BrokerBackedTerminalProcessTests: XCTestCase {
    private enum RuntimeError: Error, Equatable {
        case createFailed
    }

    private final class FailingReattachRuntime: BrokerSessionRuntime {
        let reattachError: Error

        init(reattachError: Error) {
            self.reattachError = reattachError
        }

        func listSessions() throws -> [BrokerSessionID] { [] }
        func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {}
        func detachSession(id: BrokerSessionID) throws {}
        func attachSession(id: BrokerSessionID, channelID: UUID) throws { throw reattachError }
        func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {}
        func markSessionErrored(id: BrokerSessionID) throws {}
        func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(id: BrokerSessionID) throws -> Data { Data() }
        func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data { Data() }
        func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(id: BrokerSessionID) throws -> Bool { true }
        func terminationStatus(id: BrokerSessionID) throws -> Int32? { nil }
    }

    private final class FailingCreateRuntime: BrokerSessionRuntime {
        func listSessions() throws -> [BrokerSessionID] { [] }
        func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws { throw RuntimeError.createFailed }
        func detachSession(id: BrokerSessionID) throws {}
        func attachSession(id: BrokerSessionID, channelID: UUID) throws {}
        func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {}
        func markSessionErrored(id: BrokerSessionID) throws {}
        func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(id: BrokerSessionID) throws -> Data { Data() }
        func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data { Data() }
        func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(id: BrokerSessionID) throws -> Bool { false }
        func terminationStatus(id: BrokerSessionID) throws -> Int32? { nil }
    }

    private final class StaleThenCreateRuntime: BrokerSessionRuntime {
        let staleID: BrokerSessionID
        var createdIDs: [BrokerSessionID] = []

        init(staleID: BrokerSessionID) {
            self.staleID = staleID
        }

        func listSessions() throws -> [BrokerSessionID] { createdIDs }
        func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws { createdIDs.append(id) }
        func detachSession(id: BrokerSessionID) throws {}
        func attachSession(id: BrokerSessionID, channelID: UUID) throws {
            if id == staleID {
                throw NativePTYBrokerSessionRuntime.RuntimeError.missingSession(id)
            }
        }
        func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {}
        func markSessionErrored(id: BrokerSessionID) throws {}
        func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(id: BrokerSessionID) throws -> Data { Data() }
        func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data { Data() }
        func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(id: BrokerSessionID) throws -> Bool { true }
        func terminationStatus(id: BrokerSessionID) throws -> Int32? { nil }
    }

    private final class CorruptScrollbackRuntime: BrokerSessionRuntime {
        enum Error: Swift.Error, Equatable { case corruptTail }

        func listSessions() throws -> [BrokerSessionID] { [] }
        func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {}
        func detachSession(id: BrokerSessionID) throws {}
        func attachSession(id: BrokerSessionID, channelID: UUID) throws {}
        func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {}
        func markSessionErrored(id: BrokerSessionID) throws {}
        func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(id: BrokerSessionID) throws -> Data { Data() }
        func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data { throw Error.corruptTail }
        func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(id: BrokerSessionID) throws -> Bool { true }
        func terminationStatus(id: BrokerSessionID) throws -> Int32? { nil }
    }

    private final class BlockingInputRuntime: BrokerSessionRuntime, @unchecked Sendable {
        private let lock = NSLock()
        private let entered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private var _sentInputs: [[UInt8]] = []

        var sentInputs: [[UInt8]] {
            lock.withLock { _sentInputs }
        }

        func waitForFirstWrite(timeout: TimeInterval = 1) -> Bool {
            entered.wait(timeout: .now() + timeout) == .success
        }

        func unblockWrites() {
            release.signal()
        }

        func listSessions() throws -> [BrokerSessionID] { [] }
        func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {}
        func detachSession(id: BrokerSessionID) throws {}
        func attachSession(id: BrokerSessionID, channelID: UUID) throws {}
        func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {}
        func markSessionErrored(id: BrokerSessionID) throws {}
        func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
            lock.withLock { _sentInputs.append(bytes) }
        }
        func readAvailableOutput(id: BrokerSessionID) throws -> Data { Data() }
        func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data { Data() }
        func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(id: BrokerSessionID) throws -> Bool { true }
        func terminationStatus(id: BrokerSessionID) throws -> Int32? { nil }
    }

    /// Models a broker host that accepts a session and then disappears: every
    /// follow-up operation on the live session reports transport failure until
    /// `isHostAvailable` is restored (the host coming back).
    private final class HostLossRuntime: BrokerSessionRuntime {
        var isHostAvailable = true
        private(set) var createdIDs: [BrokerSessionID] = []

        private func hostUnavailable() throws -> Never {
            throw BrokerSessionHostClientRuntime.ClientError.transportFailed(
                "socketTimedOut(/tmp/holoscape-broker.sock)"
            )
        }

        func listSessions() throws -> [BrokerSessionID] { createdIDs }
        func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {
            if !isHostAvailable { try hostUnavailable() }
            createdIDs.append(id)
        }
        func detachSession(id: BrokerSessionID) throws { if !isHostAvailable { try hostUnavailable() } }
        func attachSession(id: BrokerSessionID, channelID: UUID) throws { if !isHostAvailable { try hostUnavailable() } }
        func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws { if !isHostAvailable { try hostUnavailable() } }
        func markSessionErrored(id: BrokerSessionID) throws { if !isHostAvailable { try hostUnavailable() } }
        func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws { if !isHostAvailable { try hostUnavailable() } }
        func readAvailableOutput(id: BrokerSessionID) throws -> Data {
            if !isHostAvailable { try hostUnavailable() }
            return Data()
        }
        func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data {
            if !isHostAvailable { try hostUnavailable() }
            return Data()
        }
        func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {
            if !isHostAvailable { try hostUnavailable() }
        }
        func isRunning(id: BrokerSessionID) throws -> Bool {
            if !isHostAvailable { try hostUnavailable() }
            return true
        }
        func terminationStatus(id: BrokerSessionID) throws -> Int32? {
            if !isHostAvailable { try hostUnavailable() }
            return nil
        }
    }

    /// Models a reachable broker that no longer owns the attached session:
    /// follow-up operations report the session as missing.
    private final class MidSessionLossRuntime: BrokerSessionRuntime {
        private(set) var createdIDs: [BrokerSessionID] = []

        func listSessions() throws -> [BrokerSessionID] { createdIDs }
        func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws { createdIDs.append(id) }
        func detachSession(id: BrokerSessionID) throws {}
        func attachSession(id: BrokerSessionID, channelID: UUID) throws {}
        func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {}
        func markSessionErrored(id: BrokerSessionID) throws {}
        func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(id: BrokerSessionID) throws -> Data {
            throw NativePTYBrokerSessionRuntime.RuntimeError.missingSession(id)
        }
        func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data { Data() }
        func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(id: BrokerSessionID) throws -> Bool { true }
        func terminationStatus(id: BrokerSessionID) throws -> Int32? { nil }
    }

    /// Broker terminal wired to a temp registry so mid-session failures can be
    /// driven directly.
    private struct MidSessionFixture {
        let directory: URL
        let registry: BrokerSessionRegistry
        let coordinator: BrokerSessionCoordinator
        let terminal: BrokerBackedTerminalProcess

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func makeMidSessionFixture(
        runtime: any BrokerSessionRuntime,
        channelID: String,
        continueAfterStart: Bool = true
    ) throws -> MidSessionFixture {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerBackedTerminalProcessMidSessionTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let coordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: runtime,
            now: { Date(timeIntervalSince1970: 1_200) }
        )
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(uuidString: channelID)!,
            channelType: .shell,
            label: "broker-mid-session",
            environmentProfile: .shell,
            coordinator: coordinator
        )
        if continueAfterStart {
            terminal.startProcess(
                executable: "/bin/zsh",
                args: ["--login"],
                environment: nil,
                execName: "zsh",
                currentDirectory: "/tmp"
            )
        }
        return MidSessionFixture(
            directory: tempDirectory,
            registry: registry,
            coordinator: coordinator,
            terminal: terminal
        )
    }

    func testOutputPollAfterBrokerHostLossReportsHostFailureAndKeepsSessionForRetry() throws {
        let runtime = HostLossRuntime()
        let fixture = try makeMidSessionFixture(runtime: runtime, channelID: "00000000-0000-0000-0000-000000008010")
        defer { fixture.cleanup() }
        guard let sessionID = fixture.terminal.brokerSessionID else {
            return XCTFail("Expected the broker session to start")
        }
        var failures: [TerminalSessionFailure] = []
        fixture.terminal.setSessionFailureHandler { failures.append($0) }

        runtime.isHostAvailable = false
        fixture.terminal.pollOutputOnce()
        fixture.terminal.pollOutputOnce()
        fixture.terminal.pollOutputOnce()

        XCTAssertEqual(failures.map(\.kind), [.brokerHostUnavailable], "Repeated polls during an outage must report once, not storm")
        XCTAssertEqual(fixture.terminal.brokerSessionID, sessionID, "A host outage must keep the session handle for retry")
        XCTAssertNil(fixture.terminal.staleBrokerSessionID)
        XCTAssertEqual(try fixture.registry.load().single().lifecycle, .running, "Host loss must not mark a possibly-live session as errored")
    }

    func testSendAfterBrokerHostLossReportsHostFailureInsteadOfTrapping() throws {
        let runtime = HostLossRuntime()
        let fixture = try makeMidSessionFixture(runtime: runtime, channelID: "00000000-0000-0000-0000-000000008011")
        defer { fixture.cleanup() }
        guard let sessionID = fixture.terminal.brokerSessionID else {
            return XCTFail("Expected the broker session to start")
        }
        var failures: [TerminalSessionFailure] = []
        fixture.terminal.setSessionFailureHandler { failures.append($0) }

        runtime.isHostAvailable = false
        fixture.terminal.send(Array("hello\n".utf8))
        try waitUntil { failures.count == 1 }

        XCTAssertEqual(failures.map(\.kind), [.brokerHostUnavailable])
        XCTAssertEqual(fixture.terminal.brokerSessionID, sessionID)
        XCTAssertNil(fixture.terminal.staleBrokerSessionID)
    }

    func testBrokerInputSendReturnsBeforeSlowBrokerWriteCompletes() throws {
        let runtime = BlockingInputRuntime()
        let fixture = try makeMidSessionFixture(runtime: runtime, channelID: "00000000-0000-0000-0000-000000008016")
        defer { fixture.cleanup() }

        let started = Date()
        fixture.terminal.send(Array("slow-write\n".utf8))
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.05, "Broker-backed typing must enqueue input without waiting for socket/PTY writes")
        XCTAssertTrue(runtime.waitForFirstWrite(), "The queued write should still reach the broker lane")
        runtime.unblockWrites()
        try waitUntil { runtime.sentInputs.count == 1 }
        XCTAssertEqual(String(decoding: runtime.sentInputs[0], as: UTF8.self), "slow-write\n")
    }

    func testBrokerInputWriteLanePreservesPerSessionInputOrder() throws {
        let runtime = BlockingInputRuntime()
        let fixture = try makeMidSessionFixture(runtime: runtime, channelID: "00000000-0000-0000-0000-000000008017")
        defer { fixture.cleanup() }

        fixture.terminal.send(Array("first\n".utf8))
        fixture.terminal.send(Array("second\n".utf8))

        XCTAssertTrue(runtime.waitForFirstWrite(), "Expected the first queued write to enter the lane")
        runtime.unblockWrites()
        try waitUntil { runtime.sentInputs.count == 1 }
        runtime.unblockWrites()
        try waitUntil { runtime.sentInputs.count == 2 }

        XCTAssertEqual(runtime.sentInputs.map { String(decoding: $0, as: UTF8.self) }, ["first\n", "second\n"])
    }

    func testResizeAfterBrokerHostLossReportsHostFailureInsteadOfTrapping() throws {
        let runtime = HostLossRuntime()
        let fixture = try makeMidSessionFixture(runtime: runtime, channelID: "00000000-0000-0000-0000-000000008012")
        defer { fixture.cleanup() }
        guard let sessionID = fixture.terminal.brokerSessionID else {
            return XCTFail("Expected the broker session to start")
        }
        var failures: [TerminalSessionFailure] = []
        fixture.terminal.setSessionFailureHandler { failures.append($0) }

        runtime.isHostAvailable = false
        fixture.terminal.resizeToCurrentGrid()

        XCTAssertEqual(failures.map(\.kind), [.brokerHostUnavailable])
        XCTAssertEqual(fixture.terminal.brokerSessionID, sessionID)
        XCTAssertNil(fixture.terminal.staleBrokerSessionID)
    }

    func testRetryAfterBrokerHostLossReattachesSameSessionWithoutReplacement() throws {
        let runtime = HostLossRuntime()
        let fixture = try makeMidSessionFixture(runtime: runtime, channelID: "00000000-0000-0000-0000-000000008013")
        defer { fixture.cleanup() }
        guard let sessionID = fixture.terminal.brokerSessionID else {
            return XCTFail("Expected the broker session to start")
        }
        var failures: [TerminalSessionFailure] = []
        fixture.terminal.setSessionFailureHandler { failures.append($0) }

        runtime.isHostAvailable = false
        fixture.terminal.pollOutputOnce()
        XCTAssertEqual(failures.count, 1)

        runtime.isHostAvailable = true
        fixture.terminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh",
            currentDirectory: "/tmp"
        )

        XCTAssertNil(fixture.terminal.sessionFailure, "A successful retry must clear the recorded session failure")
        XCTAssertNil(fixture.terminal.startFailureKind)
        XCTAssertEqual(fixture.terminal.brokerSessionID, sessionID)
        XCTAssertEqual(
            runtime.createdIDs,
            [sessionID],
            "Retry after a host outage must reattach, never spawn a replacement"
        )
    }

    func testMidSessionBrokerLossReportsStaleFailureAndKeepsDeadIdentity() throws {
        let runtime = MidSessionLossRuntime()
        let fixture = try makeMidSessionFixture(runtime: runtime, channelID: "00000000-0000-0000-0000-000000008014")
        defer { fixture.cleanup() }
        var failures: [TerminalSessionFailure] = []
        fixture.terminal.setSessionFailureHandler { failures.append($0) }
        guard let sessionID = fixture.terminal.brokerSessionID else {
            return XCTFail("Expected the broker session to start")
        }

        fixture.terminal.pollOutputOnce()

        XCTAssertEqual(failures.map(\.kind), [.brokerSessionStale])
        XCTAssertNil(fixture.terminal.brokerSessionID, "A dropped session must not stay attached")
        XCTAssertEqual(fixture.terminal.staleBrokerSessionID, sessionID)
    }

    func testOperationsWithoutLiveBrokerSessionAreIgnoredWithoutReportedHostLoss() throws {
        let fixture = try makeMidSessionFixture(
            runtime: HostLossRuntime(),
            channelID: "00000000-0000-0000-0000-000000008015",
            continueAfterStart: false
        )
        defer { fixture.cleanup() }
        var failures: [TerminalSessionFailure] = []
        fixture.terminal.setSessionFailureHandler { failures.append($0) }

        // No session has ever started: a stale/disconnected tab can still receive
        // keystrokes and layout passes from the view. Those must be inert, not a
        // crash and not a fabricated host outage.
        fixture.terminal.send(Array("x".utf8))
        fixture.terminal.resizeToCurrentGrid()
        fixture.terminal.pollOutputOnce()

        XCTAssertTrue(failures.isEmpty, "A tab with no live session must not report a broker host outage")
        XCTAssertNil(fixture.terminal.sessionFailure)
    }

    func testStartCreatesBrokerRecordAndRoutesInputThroughNativePTYRuntime() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerBackedTerminalProcessTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let runtime = NativePTYBrokerSessionRuntime()
        let coordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: runtime,
            now: { Date(timeIntervalSince1970: 700) }
        )
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000008001")!
        let terminal = BrokerBackedTerminalProcess(
            channelID: channelID,
            channelType: .shell,
            label: "broker-cat",
            environmentProfile: .shell,
            coordinator: coordinator
        )
        var outputNotifications = 0
        terminal.setOutputHandler { outputNotifications += 1 }

        terminal.startProcess(
            executable: "/bin/cat",
            args: [],
            environment: nil,
            execName: "cat",
            currentDirectory: "/tmp"
        )
        guard let brokerSessionID = terminal.brokerSessionID else {
            return XCTFail("Broker-backed terminal did not expose a broker session id")
        }
        defer { _ = try? coordinator.markErrored(brokerSessionID) }
        defer { terminal.setOutputHandler(nil) }

        let record = try registry.load().single()
        XCTAssertEqual(record.id, brokerSessionID)
        XCTAssertEqual(record.channelType, .shell)
        XCTAssertEqual(record.label, "broker-cat")
        XCTAssertEqual(record.command, "/bin/cat")
        XCTAssertEqual(record.workingDirectory, "/tmp")
        XCTAssertEqual(record.environmentProfile, .shell)
        XCTAssertEqual(record.lifecycle, .running)
        XCTAssertEqual(record.lastAttachedChannelID, channelID)
        XCTAssertTrue(try coordinator.isRunning(brokerSessionID))

        terminal.send(Array("broker-terminal-bridge\n".utf8))
        try waitUntil {
            terminal.pollOutputOnce()
            return outputNotifications > 0
        }
        XCTAssertGreaterThan(outputNotifications, 0)
    }

    func testHostCurrentDirectoryUpdatesFromWrappedTerminalViewReachHandler() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerBackedTerminalProcessDirectoryTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let coordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: NativePTYBrokerSessionRuntime(),
            now: { Date(timeIntervalSince1970: 760) }
        )
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(uuidString: "00000000-0000-0000-0000-000000008021")!,
            channelType: .shell,
            label: "broker-cwd",
            environmentProfile: .shell,
            coordinator: coordinator
        )
        var observedDirectories: [String?] = []
        terminal.setHostCurrentDirectoryHandler { observedDirectories.append($0) }
        terminal.setOutputHandler {}

        terminal.startProcess(
            executable: "/bin/sh",
            args: ["-c", "printf '\\033]7;file://localhost/tmp\\007'"],
            environment: nil,
            execName: "sh",
            currentDirectory: "/tmp"
        )
        guard let brokerSessionID = terminal.brokerSessionID else {
            return XCTFail("Broker-backed terminal did not expose a broker session id")
        }
        defer { _ = try? coordinator.markErrored(brokerSessionID) }
        defer { terminal.setOutputHandler(nil) }

        try waitUntil {
            terminal.pollOutputOnce()
            return observedDirectories.contains("file://localhost/tmp")
        }
    }

    func testProcessExitUpdatesBrokerRecordAndCallsTerminationHandler() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerBackedTerminalProcessExitTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        var now = Date(timeIntervalSince1970: 800)
        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let coordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: NativePTYBrokerSessionRuntime(),
            now: { now }
        )
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(uuidString: "00000000-0000-0000-0000-000000008002")!,
            channelType: .shell,
            label: "broker-exit",
            environmentProfile: .shell,
            coordinator: coordinator
        )
        var observedExitCode: Int32?
        terminal.setTerminationHandler { observedExitCode = $0 }

        terminal.startProcess(
            executable: "/bin/sh",
            args: ["-c", "exit 3"],
            environment: nil,
            execName: "sh",
            currentDirectory: "/tmp"
        )
        now = Date(timeIntervalSince1970: 801)

        try waitUntil {
            terminal.pollOutputOnce()
            return observedExitCode != nil
        }

        XCTAssertEqual(observedExitCode, 3)
        let exited = try registry.load().single()
        XCTAssertEqual(exited.lifecycle, .exited)
        XCTAssertEqual(exited.exitCode, 3)
        XCTAssertNil(exited.lastAttachedChannelID)
        XCTAssertEqual(exited.updatedAt, now)
    }

    /// Teardown while the broker host is unreachable must not trap, and must leave
    /// the durable record reattachable: the record keeps its lifecycle, and the
    /// terminal keeps the handle the next launch reads.
    func testDetachFailureWithBrokerHostOutageKeepsRecordReattachable() throws {
        let fixture = try CoordinatorBackedBrokerFixture()
        defer { fixture.cleanup() }
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(uuidString: "00000000-0000-0000-0000-000000008020")!,
            channelType: .shell,
            label: "detach-outage",
            environmentProfile: .shell,
            coordinator: fixture.coordinator
        )
        terminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh",
            currentDirectory: "/tmp"
        )
        let sessionID = try XCTUnwrap(terminal.brokerSessionID)

        // The broker host disappears before the tab is torn down (tab close or app
        // termination).
        fixture.runtime.mode = .hostUnavailable
        terminal.detachBrokerSession()

        XCTAssertEqual(fixture.runtime.detachedIDs, [sessionID], "The detach attempt must still reach the coordinator")
        XCTAssertEqual(
            terminal.brokerOwnedSessionID,
            sessionID,
            "A failed detach must keep the handle for the next launch"
        )
        XCTAssertEqual(
            try fixture.singleRecord().lifecycle,
            .running,
            "An unrecorded detach must leave the durable record reattachable for reconcile"
        )
    }

    func testStartReattachesExistingBrokerSessionInsteadOfCreatingReplacement() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerBackedTerminalProcessReattachTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let coordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: NativePTYBrokerSessionRuntime(),
            now: { Date(timeIntervalSince1970: 900) }
        )
        let originalChannelID = UUID(uuidString: "00000000-0000-0000-0000-000000008003")!
        let restoredChannelID = UUID(uuidString: "00000000-0000-0000-0000-000000008004")!
        let record = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/bin/cat",
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .shell,
            label: "broker-reattach",
            attachedChannelID: originalChannelID
        )
        try coordinator.sendInput(record.id, bytes: Array("before-ui-restore\n".utf8))
        _ = try waitForBrokerOutput(from: coordinator, id: record.id, containing: "before-ui-restore")
        _ = try coordinator.detach(record.id)

        let restoredTerminal = BrokerBackedTerminalProcess(
            channelID: restoredChannelID,
            channelType: .shell,
            label: "broker-reattach",
            environmentProfile: .shell,
            existingBrokerSessionID: record.id,
            coordinator: coordinator
        )
        var outputNotifications = 0
        restoredTerminal.setOutputHandler { outputNotifications += 1 }

        restoredTerminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh",
            currentDirectory: "/tmp"
        )
        restoredTerminal.send(Array("after-ui-restore\n".utf8))
        try waitUntil {
            restoredTerminal.pollOutputOnce()
            return outputNotifications > 0
        }

        let sessions = try registry.load()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, record.id)
        XCTAssertEqual(sessions[0].command, "/bin/cat")
        XCTAssertEqual(sessions[0].lifecycle, .running)
        XCTAssertEqual(sessions[0].lastAttachedChannelID, restoredChannelID)
        XCTAssertEqual(restoredTerminal.brokerSessionID, record.id)
        XCTAssertEqual(restoredTerminal.lastScrollbackReplay?.source, .liveBrokerMemory)
        XCTAssertTrue(restoredTerminal.lastLines(20).joined(separator: "\n").contains("live broker memory"))
        XCTAssertTrue(try coordinator.isRunning(record.id))
    }

    func testCorruptScrollbackReplayDoesNotFailSuccessfulReattach() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerBackedTerminalProcessCorruptScrollbackTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sessionID = BrokerSessionID(rawValue: "corrupt-scrollback-reattach")
        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        try registry.upsert(BrokerSessionRecord(
            id: sessionID,
            channelType: .shell,
            label: "Shell",
            command: "/bin/zsh",
            arguments: ["--login"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            lifecycle: .detached,
            exitCode: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            lastAttachedChannelID: nil
        ))
        let coordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: CorruptScrollbackRuntime(),
            now: { Date(timeIntervalSince1970: 2) }
        )
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(uuidString: "00000000-0000-0000-0000-000000008030")!,
            channelType: .shell,
            label: "Shell",
            environmentProfile: .shell,
            existingBrokerSessionID: sessionID,
            coordinator: coordinator
        )

        terminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh",
            currentDirectory: "/tmp"
        )

        XCTAssertEqual(terminal.brokerSessionID, sessionID)
        XCTAssertNil(terminal.startFailureKind)
        XCTAssertNil(terminal.lastScrollbackReplay)
        XCTAssertTrue(terminal.lastLines(20).joined(separator: "\n").contains("could not restore its persisted scrollback"))
        XCTAssertEqual(try registry.load().single().lifecycle, .running)
    }

    func testStartFailureIsObservableAndDoesNotExposePhantomBrokerSession() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerBackedTerminalProcessFailureTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let coordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: FailingCreateRuntime(),
            now: { Date(timeIntervalSince1970: 950) }
        )
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(uuidString: "00000000-0000-0000-0000-000000008005")!,
            channelType: .shell,
            label: "broker-failure",
            environmentProfile: .shell,
            coordinator: coordinator
        )

        terminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh",
            currentDirectory: "/tmp"
        )

        XCTAssertNil(terminal.brokerSessionID)
        XCTAssertTrue(terminal.startFailureDescription?.contains("createFailed") == true, terminal.startFailureDescription ?? "nil")
        XCTAssertEqual(terminal.startFailureKind, .failed)
        XCTAssertEqual(try registry.load(), [])
    }

    func testReattachMissingRuntimeSessionIsObservableAsStaleAndMarksRecordStale() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerBackedTerminalProcessStaleReattachTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sessionID = BrokerSessionID(rawValue: "stale-restored-agent-session")
        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        try registry.upsert(BrokerSessionRecord(
            id: sessionID,
            channelType: .agentDirect,
            label: "Codex",
            command: "/usr/bin/env",
            arguments: ["codex"],
            workingDirectory: "/tmp/stale-agent",
            environmentProfile: .agentOAuth,
            lifecycle: .detached,
            exitCode: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            lastAttachedChannelID: nil
        ))
        let coordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: FailingReattachRuntime(reattachError: NativePTYBrokerSessionRuntime.RuntimeError.missingSession(sessionID)),
            now: { Date(timeIntervalSince1970: 2) }
        )
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(uuidString: "00000000-0000-0000-0000-000000008006")!,
            channelType: .agentDirect,
            label: "Codex",
            environmentProfile: .agentOAuth,
            existingBrokerSessionID: sessionID,
            coordinator: coordinator
        )

        terminal.startProcess(
            executable: "/usr/bin/env",
            args: ["codex"],
            environment: nil,
            execName: "codex",
            currentDirectory: "/tmp/stale-agent"
        )

        XCTAssertNil(terminal.brokerSessionID)
        XCTAssertEqual(terminal.startFailureKind, .brokerSessionStale)
        XCTAssertEqual(
            terminal.staleBrokerSessionID,
            sessionID,
            "The dead session identity must be reported so the owning tab can persist its recreate guidance"
        )
        let stale = try registry.load().single()
        XCTAssertEqual(stale.lifecycle, .stale)
        XCTAssertNil(stale.lastAttachedChannelID)
    }

    func testReattachBrokerHostUnavailablePreservesSessionIDForRetry() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerBackedTerminalProcessHostUnavailableReattachTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sessionID = BrokerSessionID(rawValue: "host-unavailable-restored-agent-session")
        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let record = BrokerSessionRecord(
            id: sessionID,
            channelType: .agentDirect,
            label: "Codex",
            command: "/usr/bin/env",
            arguments: ["codex"],
            workingDirectory: "/tmp/host-unavailable-agent",
            environmentProfile: .agentOAuth,
            lifecycle: .detached,
            exitCode: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            lastAttachedChannelID: nil
        )
        try registry.upsert(record)
        let coordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: FailingReattachRuntime(reattachError: BrokerSessionHostClientRuntime.ClientError.transportFailed("socketTimedOut(/tmp/missing.sock)")),
            now: { Date(timeIntervalSince1970: 2) }
        )
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(uuidString: "00000000-0000-0000-0000-000000008007")!,
            channelType: .agentDirect,
            label: "Codex",
            environmentProfile: .agentOAuth,
            existingBrokerSessionID: sessionID,
            coordinator: coordinator
        )

        terminal.startProcess(
            executable: "/usr/bin/env",
            args: ["codex"],
            environment: nil,
            execName: "codex",
            currentDirectory: "/tmp/host-unavailable-agent"
        )

        XCTAssertEqual(terminal.brokerSessionID, sessionID)
        XCTAssertEqual(terminal.startFailureKind, .brokerHostUnavailable)
        XCTAssertEqual(try registry.load(), [record])
    }

    func testRetryAfterStaleReattachCreatesReplacementBrokerSession() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerBackedTerminalProcessStaleRetryTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let staleID = BrokerSessionID(rawValue: "stale-retry-restored-agent-session")
        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        try registry.upsert(BrokerSessionRecord(
            id: staleID,
            channelType: .agentDirect,
            label: "Codex",
            command: "/usr/bin/env",
            arguments: ["codex"],
            workingDirectory: "/tmp/stale-retry-agent",
            environmentProfile: .agentOAuth,
            lifecycle: .detached,
            exitCode: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            lastAttachedChannelID: nil
        ))
        let runtime = StaleThenCreateRuntime(staleID: staleID)
        var now = Date(timeIntervalSince1970: 2)
        let coordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: runtime,
            now: { now }
        )
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(uuidString: "00000000-0000-0000-0000-000000008008")!,
            channelType: .agentDirect,
            label: "Codex",
            environmentProfile: .agentOAuth,
            existingBrokerSessionID: staleID,
            coordinator: coordinator
        )

        terminal.startProcess(
            executable: "/usr/bin/env",
            args: ["codex"],
            environment: nil,
            execName: "codex",
            currentDirectory: "/tmp/stale-retry-agent"
        )
        XCTAssertNil(terminal.brokerSessionID)
        XCTAssertEqual(terminal.startFailureKind, .brokerSessionStale)
        XCTAssertEqual(terminal.staleBrokerSessionID, staleID)

        now = Date(timeIntervalSince1970: 3)
        terminal.startProcess(
            executable: "/usr/bin/env",
            args: ["codex"],
            environment: nil,
            execName: "codex",
            currentDirectory: "/tmp/stale-retry-agent"
        )

        guard let replacementID = terminal.brokerSessionID else {
            return XCTFail("Expected stale retry to create a replacement broker session")
        }
        XCTAssertNil(terminal.startFailureKind)
        XCTAssertNil(terminal.staleBrokerSessionID, "A replacement session clears the dead identity")
        XCTAssertNotEqual(replacementID, staleID)
        XCTAssertEqual(runtime.createdIDs, [replacementID])
        let records = try registry.load().sorted { $0.createdAt < $1.createdAt }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].id, staleID)
        XCTAssertEqual(records[0].lifecycle, .stale)
        XCTAssertEqual(records[1].id, replacementID)
        XCTAssertEqual(records[1].lifecycle, .running)
        XCTAssertEqual(records[1].command, "/usr/bin/env")
        XCTAssertEqual(records[1].arguments, ["codex"])
        XCTAssertEqual(records[1].workingDirectory, "/tmp/stale-retry-agent")
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: () throws -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    private func waitForBrokerOutput(
        from coordinator: BrokerSessionCoordinator,
        id: BrokerSessionID,
        containing expected: String,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        var collected = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            collected.append(try coordinator.readAvailableOutput(id))
            let output = String(decoding: collected, as: UTF8.self)
            if output.contains(expected) {
                return output
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let output = String(decoding: collected, as: UTF8.self)
        XCTFail("Timed out waiting for broker output containing \(expected). Saw: \(output)", file: file, line: line)
        return output
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension Array {
    func single(file: StaticString = #filePath, line: UInt = #line) throws -> Element {
        XCTAssertEqual(count, 1, file: file, line: line)
        return self[0]
    }
}
