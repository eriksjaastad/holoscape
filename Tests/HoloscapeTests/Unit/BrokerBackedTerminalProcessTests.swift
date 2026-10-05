import XCTest
@testable import Holoscape

@MainActor
final class BrokerBackedTerminalProcessTests: XCTestCase {
    private final class BlockingReattachCoordinator: BrokerSessionCoordinating, @unchecked Sendable {
        let requiresOffMainBrokerWork = true
        private let entered = DispatchSemaphore(value: 0)
        private let release = DispatchSemaphore(value: 0)
        private let returned = DispatchSemaphore(value: 0)
        private let teardownEntered = DispatchSemaphore(value: 0)
        private let teardownRelease = DispatchSemaphore(value: 0)
        private let startEntered = DispatchSemaphore(value: 0)
        private let startRelease = DispatchSemaphore(value: 0)
        private let resizeEntered = DispatchSemaphore(value: 0)
        private let resizeRelease = DispatchSemaphore(value: 0)
        private let outputSnapshotEntered = DispatchSemaphore(value: 0)
        private let outputSnapshotRelease = DispatchSemaphore(value: 0)
        private let inputWriteEntered = DispatchSemaphore(value: 0)
        private let inputWriteRelease = DispatchSemaphore(value: 0)
        private let acknowledgmentRelease = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private(set) var detachCalls: [BrokerSessionID] = []
        private(set) var markErroredCalls: [BrokerSessionID] = []
        private(set) var teardownRanOnMainThread: [Bool] = []
        private(set) var startRanOnMainThread: [Bool] = []
        private(set) var outputReadCount = 0
        private(set) var resizeRanOnMainThread: [Bool] = []
        private var shouldBlockTeardown = false
        private var shouldBlockStart = false
        private var shouldBlockResize = false
        private var blockedResizeShouldFail = false
        private var shouldBlockOutputSnapshot = false
        private var shouldBlockInputWrite = false
        private var blockedInputWriteShouldFail = false
        private var shouldBlockAcknowledgment = false
        private var storedAcknowledgedOutputGenerations: [UInt64] = []
        private var storedScrollbackSnapshotCount = 0
        private var storedSuccessfulInputWrites = 0
        var untrackedStartID: BrokerSessionID?
        private(set) var reattachCallCount = 0

        func waitForReattach(timeout: TimeInterval = 1) -> Bool {
            entered.wait(timeout: .now() + timeout) == .success
        }

        func finishReattach() { release.signal() }

        func waitForReattachReturn(timeout: TimeInterval = 1) -> Bool {
            returned.wait(timeout: .now() + timeout) == .success
        }

        func blockTeardown() { lock.withLock { shouldBlockTeardown = true } }
        func waitForTeardown(timeout: TimeInterval = 1) -> Bool {
            teardownEntered.wait(timeout: .now() + timeout) == .success
        }
        func finishTeardown() { teardownRelease.signal() }

        func blockStart() { lock.withLock { shouldBlockStart = true } }
        func waitForStart(timeout: TimeInterval = 1) -> Bool {
            startEntered.wait(timeout: .now() + timeout) == .success
        }
        var startCallCount: Int { lock.withLock { startRanOnMainThread.count } }
        func finishStart() { startRelease.signal() }

        func blockResize() { lock.withLock { shouldBlockResize = true } }
        func blockNextResize(fail: Bool) {
            lock.withLock {
                shouldBlockResize = true
                blockedResizeShouldFail = fail
            }
        }
        func waitForResize(timeout: TimeInterval = 1) -> Bool {
            resizeEntered.wait(timeout: .now() + timeout) == .success
        }
        func finishResize() { resizeRelease.signal() }

        func blockOutputSnapshot() { lock.withLock { shouldBlockOutputSnapshot = true } }
        func waitForOutputSnapshot(timeout: TimeInterval = 1) -> Bool {
            outputSnapshotEntered.wait(timeout: .now() + timeout) == .success
        }
        func finishOutputSnapshot() { outputSnapshotRelease.signal() }
        var acknowledgedOutputGenerations: [UInt64] {
            lock.withLock { storedAcknowledgedOutputGenerations }
        }
        var scrollbackSnapshotCount: Int { lock.withLock { storedScrollbackSnapshotCount } }
        func blockAcknowledgment() { lock.withLock { shouldBlockAcknowledgment = true } }
        func finishAcknowledgment() { acknowledgmentRelease.signal() }

        func blockNextInputWrite(fail: Bool) {
            lock.withLock {
                shouldBlockInputWrite = true
                blockedInputWriteShouldFail = fail
            }
        }
        func waitForInputWrite(timeout: TimeInterval = 1) -> Bool {
            inputWriteEntered.wait(timeout: .now() + timeout) == .success
        }
        func finishInputWrite() { inputWriteRelease.signal() }
        var successfulInputWrites: Int { lock.withLock { storedSuccessfulInputWrites } }

        func start(_ request: BrokerSessionLaunchRequest, channelType: ChannelType, label: String?, attachedChannelID: UUID?) throws -> BrokerSessionRecord {
            let shouldBlock = lock.withLock { () -> Bool in
                startRanOnMainThread.append(Thread.isMainThread)
                return shouldBlockStart
            }
            if shouldBlock {
                startEntered.signal()
                _ = startRelease.wait(timeout: .now() + 2)
            }
            if let untrackedStartID {
                throw BrokerSessionCoordinator.CoordinatorError.untrackedSession(
                    untrackedStartID,
                    registryFailure: "registry failed",
                    rollbackFailure: "rollback failed"
                )
            }
            return record(id: BrokerSessionID(rawValue: "started-off-main"), ownerToken: nil, lifecycle: .running)
        }
        func detach(_ id: BrokerSessionID) throws -> BrokerSessionRecord {
            let shouldBlock = lock.withLock { () -> Bool in
                detachCalls.append(id)
                teardownRanOnMainThread.append(Thread.isMainThread)
                return shouldBlockTeardown
            }
            if shouldBlock {
                teardownEntered.signal()
                _ = teardownRelease.wait(timeout: .now() + 2)
            }
            return record(id: id, ownerToken: nil, lifecycle: .detached)
        }
        func retireUntrackedSession(_ id: BrokerSessionID) throws {
            let shouldBlock = lock.withLock { () -> Bool in
                detachCalls.append(id)
                teardownRanOnMainThread.append(Thread.isMainThread)
                return shouldBlockTeardown
            }
            if shouldBlock {
                teardownEntered.signal()
                _ = teardownRelease.wait(timeout: .now() + 2)
            }
        }
        func reattach(_ id: BrokerSessionID, attachedChannelID: UUID) throws -> BrokerSessionRecord {
            lock.withLock { reattachCallCount += 1 }
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
            returned.signal()
            return record(id: id, ownerToken: "late-owner", lifecycle: .running)
        }
        func reattachableSessions() throws -> [BrokerSessionRecord] { [] }
        func exit(_ id: BrokerSessionID, exitCode: Int32) throws -> BrokerSessionRecord { throw XCTSkip("unused") }
        func markErrored(_ id: BrokerSessionID) throws -> BrokerSessionRecord {
            lock.withLock { markErroredCalls.append(id) }
            return record(id: id, ownerToken: nil, lifecycle: .errored)
        }
        func updateWorkingDirectory(_ id: BrokerSessionID, to directory: String) throws -> BrokerSessionRecord { throw XCTSkip("unused") }
        func sendInput(_ id: BrokerSessionID, bytes: [UInt8]) throws {
            let blocked: (shouldBlock: Bool, shouldFail: Bool) = lock.withLock {
                let result = (shouldBlockInputWrite, blockedInputWriteShouldFail)
                shouldBlockInputWrite = false
                blockedInputWriteShouldFail = false
                return result
            }
            if blocked.shouldBlock {
                inputWriteEntered.signal()
                _ = inputWriteRelease.wait(timeout: .now() + 2)
            }
            if blocked.shouldFail {
                throw RuntimeError.createFailed
            }
            lock.withLock { storedSuccessfulInputWrites += 1 }
        }
        func readAvailableOutput(_ id: BrokerSessionID) throws -> Data {
            lock.withLock { outputReadCount += 1 }
            return Data()
        }
        func snapshotAvailableOutput(_ id: BrokerSessionID) throws -> BrokerOutputSnapshot {
            let shouldBlock = lock.withLock { () -> Bool in
                outputReadCount += 1
                return shouldBlockOutputSnapshot
            }
            if shouldBlock {
                outputSnapshotEntered.signal()
                _ = outputSnapshotRelease.wait(timeout: .now() + 2)
            }
            return BrokerOutputSnapshot(data: Data("cancelled-before-delivery".utf8), generation: 42)
        }
        func acknowledgeOutput(_ id: BrokerSessionID, through generation: UInt64) throws {
            let shouldBlock = lock.withLock { () -> Bool in
                storedAcknowledgedOutputGenerations.append(generation)
                return shouldBlockAcknowledgment
            }
            if shouldBlock {
                _ = acknowledgmentRelease.wait(timeout: .now() + 2)
            }
        }
        func readScrollbackTail(_ id: BrokerSessionID, maxBytes: Int) throws -> Data { Data() }
        func snapshotScrollbackReplay(_ id: BrokerSessionID, maxBytes: Int) throws -> BrokerScrollbackReplaySnapshot {
            lock.withLock { storedScrollbackSnapshotCount += 1 }
            return BrokerScrollbackReplaySnapshot(
                replay: ScrollbackReplay(
                    data: Data("one-time-replay\n".utf8),
                    source: .liveBrokerMemory,
                    maxBytes: maxBytes
                ),
                generation: 41
            )
        }
        func resize(_ id: BrokerSessionID, size: TerminalGridSize) throws {
            let blocked: (shouldBlock: Bool, shouldFail: Bool) = lock.withLock {
                resizeRanOnMainThread.append(Thread.isMainThread)
                let result = (shouldBlockResize, blockedResizeShouldFail)
                shouldBlockResize = false
                blockedResizeShouldFail = false
                return result
            }
            if blocked.shouldBlock {
                resizeEntered.signal()
                _ = resizeRelease.wait(timeout: .now() + 2)
            }
            if blocked.shouldFail {
                throw RuntimeError.createFailed
            }
        }
        func isRunning(_ id: BrokerSessionID) throws -> Bool { true }
        func terminationStatus(_ id: BrokerSessionID) throws -> Int32? { nil }
        func reconcileRuntimeStatus(_ id: BrokerSessionID) throws -> BrokerSessionRecord { throw XCTSkip("unused") }

        private func record(id: BrokerSessionID, ownerToken: String?, lifecycle: BrokerSessionLifecycle) -> BrokerSessionRecord {
            BrokerSessionRecord(
                id: id,
                channelType: .agentDirect,
                label: "agent",
                command: "/usr/bin/env",
                arguments: ["codex"],
                workingDirectory: "/tmp",
                environmentProfile: .agentOAuth,
                agentStatusOwnerToken: ownerToken,
                lifecycle: lifecycle,
                exitCode: nil,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2),
                lastAttachedChannelID: nil
            )
        }
    }

    private final class ExitedUnreadOutputCoordinator: BrokerSessionCoordinating {
        let requiresOffMainBrokerWork = true
        let sessionID = BrokerSessionID(rawValue: "exited-unread-output")
        private(set) var outputReadCount = 0
        private(set) var acknowledgedGenerations: [UInt64] = []
        private(set) var retiredSessionIDs: [BrokerSessionID] = []
        private(set) var finalizedExitCodes: [Int32] = []
        var restoredLifecycle: BrokerSessionLifecycle = .exited
        var requestedExitCode: Int32?
        var terminationStatusError: Error?
        var finalizationError: Error?
        var retirementError: Error?
        private let outputReadRelease = DispatchSemaphore(value: 0)
        private var shouldBlockOutputRead = false

        func blockOutputRead() { shouldBlockOutputRead = true }
        func finishOutputRead() { outputReadRelease.signal() }

        private func restoredRecord(id: BrokerSessionID) -> BrokerSessionRecord {
            BrokerSessionRecord(
                id: id,
                channelType: .shell,
                label: "finished",
                command: "/bin/sh",
                arguments: [],
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                lifecycle: restoredLifecycle,
                exitCode: restoredLifecycle == .exited ? 9 : nil,
                requestedExitCode: requestedExitCode,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2),
                lastAttachedChannelID: nil
            )
        }

        func start(_ request: BrokerSessionLaunchRequest, channelType: ChannelType, label: String?, attachedChannelID: UUID?) throws -> BrokerSessionRecord {
            throw XCTSkip("unused")
        }
        func detach(_ id: BrokerSessionID) throws -> BrokerSessionRecord { restoredRecord(id: id) }
        func retireUntrackedSession(_ id: BrokerSessionID) throws { throw XCTSkip("unused") }
        func reattach(_ id: BrokerSessionID, attachedChannelID: UUID) throws -> BrokerSessionRecord {
            restoredRecord(id: id)
        }
        func retireCompletedSession(_ id: BrokerSessionID) throws {
            retiredSessionIDs.append(id)
            if let retirementError { throw retirementError }
        }
        func reattachableSessions() throws -> [BrokerSessionRecord] { [] }
        func exit(_ id: BrokerSessionID, exitCode: Int32) throws -> BrokerSessionRecord {
            finalizedExitCodes.append(exitCode)
            if let finalizationError { throw finalizationError }
            restoredLifecycle = .exited
            return restoredRecord(id: id)
        }
        func markErrored(_ id: BrokerSessionID) throws -> BrokerSessionRecord { throw XCTSkip("unused") }
        func updateWorkingDirectory(_ id: BrokerSessionID, to directory: String) throws -> BrokerSessionRecord { throw XCTSkip("unused") }
        func sendInput(_ id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(_ id: BrokerSessionID) throws -> Data {
            outputReadCount += 1
            if shouldBlockOutputRead {
                _ = outputReadRelease.wait(timeout: .now() + 1)
            }
            return Data("detached-final-overflow\n".utf8)
        }
        func snapshotAvailableOutput(_ id: BrokerSessionID) throws -> BrokerOutputSnapshot {
            outputReadCount += 1
            if shouldBlockOutputRead {
                _ = outputReadRelease.wait(timeout: .now() + 1)
            }
            switch outputReadCount {
            case 1:
                return BrokerOutputSnapshot(data: Data("detached-final-chunk-one\n".utf8), generation: 24)
            case 2:
                return BrokerOutputSnapshot(data: Data("detached-final-chunk-two\n".utf8), generation: 48)
            default:
                return BrokerOutputSnapshot(data: Data(), generation: nil)
            }
        }
        func acknowledgeOutput(_ id: BrokerSessionID, through generation: UInt64) throws {
            acknowledgedGenerations.append(generation)
        }
        func readScrollbackTail(_ id: BrokerSessionID, maxBytes: Int) throws -> Data { Data() }
        func readScrollbackReplay(_ id: BrokerSessionID, maxBytes: Int) throws -> ScrollbackReplay {
            ScrollbackReplay(data: Data(), source: .liveBrokerMemory, maxBytes: maxBytes)
        }
        func resize(_ id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(_ id: BrokerSessionID) throws -> Bool { false }
        func terminationStatus(_ id: BrokerSessionID) throws -> Int32? {
            if let terminationStatusError { throw terminationStatusError }
            return 9
        }
        func reconcileRuntimeStatus(_ id: BrokerSessionID) throws -> BrokerSessionRecord { throw XCTSkip("unused") }
    }

    func testWorkingDirectoryUpdatePersistsThroughOwnedBrokerSession() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerBackedTerminalProcessCWDTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        var now = Date(timeIntervalSince1970: 10)
        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let coordinator = BrokerSessionCoordinator(registry: registry, now: { now })
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(uuidString: "00000000-0000-0000-0000-000000000993")!,
            channelType: .shell,
            label: "work",
            environmentProfile: .shell,
            coordinator: coordinator
        )
        terminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh",
            currentDirectory: "/Users/test/work"
        )
        let started = try registry.load().single()

        now = Date(timeIntervalSince1970: 20)
        try terminal.updateWorkingDirectory("/Users/test/work/subdir")

        let updated = try registry.load().single()
        XCTAssertEqual(updated.id, started.id)
        XCTAssertEqual(updated.workingDirectory, "/Users/test/work/subdir")
        XCTAssertEqual(updated.updatedAt, now)
        XCTAssertEqual(updated.lifecycle, .running)
        XCTAssertEqual(updated.lastAttachedChannelID, started.lastAttachedChannelID)
    }

    func testOwnerTokenExtractionIsRestrictedToAgentChannels() {
        let environment = ["HOLOSCAPE_AGENT_STATUS_OWNER_TOKEN=agent-owner"]

        XCTAssertEqual(
            BrokerBackedTerminalProcess.agentStatusOwnerToken(
                from: environment,
                channelType: .agentDirect
            ),
            "agent-owner"
        )
        XCTAssertNil(
            BrokerBackedTerminalProcess.agentStatusOwnerToken(
                from: environment,
                channelType: .shell
            )
        )
        XCTAssertNil(
            BrokerBackedTerminalProcess.agentStatusOwnerToken(
                from: ["HOLOSCAPE_AGENT_STATUS_OWNER_TOKEN="],
                channelType: .agentDirect
            )
        )
    }
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

    private final class BlockingUntrackedRetirementRuntime: BrokerSessionRuntime, @unchecked Sendable {
        private let retirementEntered = DispatchSemaphore(value: 0)
        private let retirementRelease = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private(set) var createdIDs: [BrokerSessionID] = []
        private(set) var retirementAttempts: [BrokerSessionID] = []

        func waitForRetirement(timeout: TimeInterval = 1) -> Bool {
            retirementEntered.wait(timeout: .now() + timeout) == .success
        }

        func unblockRetirement() { retirementRelease.signal() }

        func listSessions() throws -> [BrokerSessionID] { lock.withLock { createdIDs } }
        func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {
            try lock.withLock {
                if !createdIDs.isEmpty { throw RuntimeError.createFailed }
                createdIDs.append(id)
            }
        }
        func detachSession(id: BrokerSessionID) throws {}
        func attachSession(id: BrokerSessionID, channelID: UUID) throws {}
        func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {}
        func markSessionErrored(id: BrokerSessionID) throws {
            let attempt = lock.withLock { () -> Int in
                retirementAttempts.append(id)
                return retirementAttempts.count
            }
            if attempt == 1 { throw RuntimeError.createFailed }
            retirementEntered.signal()
            _ = retirementRelease.wait(timeout: .now() + 2)
        }
        func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(id: BrokerSessionID) throws -> Data { Data() }
        func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data { Data() }
        func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(id: BrokerSessionID) throws -> Bool { true }
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

    private final class NonMainOutputReadRuntime: BrokerSessionRuntime, @unchecked Sendable {
        private let lock = NSLock()
        private var remainingPayloads: [Data]
        private(set) var readThreads: [Bool] = []
        private(set) var livenessThreads: [Bool] = []

        init(payloads: [Data]) {
            self.remainingPayloads = payloads
        }

        var didReadOnMainThread: Bool {
            lock.withLock { readThreads.contains(true) }
        }

        var didCheckLivenessOnMainThread: Bool {
            lock.withLock { livenessThreads.contains(true) }
        }

        func listSessions() throws -> [BrokerSessionID] { [] }
        func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {}
        func detachSession(id: BrokerSessionID) throws {}
        func attachSession(id: BrokerSessionID, channelID: UUID) throws {}
        func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {}
        func markSessionErrored(id: BrokerSessionID) throws {}
        func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(id: BrokerSessionID) throws -> Data {
            lock.withLock {
                readThreads.append(Thread.isMainThread)
                guard !remainingPayloads.isEmpty else { return Data() }
                return remainingPayloads.removeFirst()
            }
        }
        func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data { Data() }
        func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(id: BrokerSessionID) throws -> Bool {
            lock.withLock { livenessThreads.append(Thread.isMainThread) }
            return true
        }
        func terminationStatus(id: BrokerSessionID) throws -> Int32? {
            lock.withLock { livenessThreads.append(Thread.isMainThread) }
            return nil
        }
    }

    private final class SignaledOutputRuntime: BrokerSessionRuntime, BrokerOutputAvailabilityMonitoringRuntime, @unchecked Sendable {
        private let lock = NSLock()
        private var createdIDs: [BrokerSessionID] = []
        private var output = Data()
        private var handler: (@Sendable (BrokerSessionID) -> Void)?
        private(set) var readCount = 0

        func triggerOutput(_ text: String, for id: BrokerSessionID) {
            let currentHandler: (@Sendable (BrokerSessionID) -> Void)?
            lock.lock()
            output.append(Data(text.utf8))
            currentHandler = handler
            lock.unlock()
            currentHandler?(id)
        }

        func listSessions() throws -> [BrokerSessionID] { lock.withLock { createdIDs } }
        func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws { lock.withLock { createdIDs.append(id) } }
        func detachSession(id: BrokerSessionID) throws {}
        func attachSession(id: BrokerSessionID, channelID: UUID) throws {}
        func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {}
        func markSessionErrored(id: BrokerSessionID) throws {}
        func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(id: BrokerSessionID) throws -> Data {
            lock.withLock {
                readCount += 1
                let data = output
                output.removeAll(keepingCapacity: true)
                return data
            }
        }
        func setOutputAvailabilityHandler(id: BrokerSessionID, handler: (@Sendable (BrokerSessionID) -> Void)?) throws {
            lock.withLock { self.handler = handler }
        }
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
        var scrollbackTail = Data()
        private(set) var scrollbackTailReadCount = 0

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
            scrollbackTailReadCount += 1
            return scrollbackTail
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

    private final class ScrollbackPersistenceFailureRuntime: BrokerSessionRuntime, @unchecked Sendable {
        private let retirementEntered = DispatchSemaphore(value: 0)
        private let retirementRelease = DispatchSemaphore(value: 0)
        private(set) var createdIDs: [BrokerSessionID] = []
        private(set) var retiredIDs: [BrokerSessionID] = []
        var retirementError: Error?
        var blocksRetirement = false

        func waitForRetirement(timeout: TimeInterval = 1) -> Bool {
            retirementEntered.wait(timeout: .now() + timeout) == .success
        }

        func unblockRetirement() {
            retirementRelease.signal()
        }

        func listSessions() throws -> [BrokerSessionID] { createdIDs.filter { !retiredIDs.contains($0) } }
        func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws { createdIDs.append(id) }
        func detachSession(id: BrokerSessionID) throws {}
        func attachSession(id: BrokerSessionID, channelID: UUID) throws {}
        func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {}
        func markSessionErrored(id: BrokerSessionID) throws {
            retirementEntered.signal()
            if blocksRetirement {
                _ = retirementRelease.wait(timeout: .now() + 2)
            }
            if let retirementError {
                if case NativePTYBrokerSessionRuntime.RuntimeError.retirementCompletedWithOutputFailure = retirementError {
                    retiredIDs.append(id)
                }
                throw retirementError
            }
            retiredIDs.append(id)
        }
        func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(id: BrokerSessionID) throws -> Data {
            throw NativePTYBrokerSessionRuntime.RuntimeError.scrollbackPersistenceFailed(id, reason: "disk full")
        }
        func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data { Data() }
        func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(id: BrokerSessionID) throws -> Bool { !retiredIDs.contains(id) }
        func terminationStatus(id: BrokerSessionID) throws -> Int32? { nil }
    }

    private final class FinalOutputRuntime: BrokerSessionRuntime, BrokerOutputAvailabilityMonitoringRuntime, BrokerTransactionalOutputRuntime, @unchecked Sendable {
        private let lock = NSLock()
        private let transactionalChunkSize: Int
        private var createdIDs: [BrokerSessionID] = []
        private var retiredIDs: [BrokerSessionID] = []
        private var output = Data()
        private var outputStartOffset: UInt64 = 0
        private var storedAcknowledgedGenerations: [UInt64] = []
        private var running = true
        private var outputAfterTerminationCheck = Data()
        private var handler: (@Sendable (BrokerSessionID) -> Void)?

        init(transactionalChunkSize: Int = .max) {
            self.transactionalChunkSize = transactionalChunkSize
        }

        var acknowledgedGenerations: [UInt64] {
            lock.withLock { storedAcknowledgedGenerations }
        }

        func triggerFinalOutput(_ text: String, afterTerminationCheck lateText: String = "", for id: BrokerSessionID) {
            let currentHandler: (@Sendable (BrokerSessionID) -> Void)? = lock.withLock {
                output.append(Data(text.utf8))
                outputAfterTerminationCheck = Data(lateText.utf8)
                running = false
                return handler
            }
            currentHandler?(id)
        }

        func listSessions() throws -> [BrokerSessionID] {
            lock.withLock { createdIDs.filter { !retiredIDs.contains($0) } }
        }
        func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {
            lock.withLock { createdIDs.append(id) }
        }
        func detachSession(id: BrokerSessionID) throws {}
        func attachSession(id: BrokerSessionID, channelID: UUID) throws {}
        func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {}
        func markSessionErrored(id: BrokerSessionID) throws {
            lock.withLock { retiredIDs.append(id) }
        }
        func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(id: BrokerSessionID) throws -> Data {
            lock.withLock {
                let data = output
                outputStartOffset += UInt64(data.count)
                output.removeAll(keepingCapacity: true)
                return data
            }
        }
        func snapshotAvailableOutput(id: BrokerSessionID, maxBytes: Int) throws -> BrokerOutputSnapshot {
            lock.withLock {
                let count = min(output.count, max(0, min(maxBytes, transactionalChunkSize)))
                let data = Data(output.prefix(count))
                return BrokerOutputSnapshot(
                    data: data,
                    generation: data.isEmpty ? nil : outputStartOffset + UInt64(data.count)
                )
            }
        }
        func acknowledgeOutput(id: BrokerSessionID, through generation: UInt64) throws {
            lock.withLock {
                let count = min(output.count, Int(generation - outputStartOffset))
                output.removeFirst(count)
                outputStartOffset += UInt64(count)
                storedAcknowledgedGenerations.append(generation)
            }
        }
        func snapshotScrollbackReplay(id: BrokerSessionID, maxBytes: Int) throws -> BrokerScrollbackReplaySnapshot {
            BrokerScrollbackReplaySnapshot(
                replay: ScrollbackReplay(data: Data(), source: .liveBrokerMemory, maxBytes: maxBytes),
                generation: nil
            )
        }
        func setOutputAvailabilityHandler(id: BrokerSessionID, handler: (@Sendable (BrokerSessionID) -> Void)?) throws {
            lock.withLock { self.handler = handler }
        }
        func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data { Data() }
        func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(id: BrokerSessionID) throws -> Bool { lock.withLock { running } }
        func terminationStatus(id: BrokerSessionID) throws -> Int32? {
            lock.withLock {
                guard !running else { return nil }
                output.append(outputAfterTerminationCheck)
                outputAfterTerminationCheck.removeAll()
                return 0
            }
        }
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
        try waitUntil { failures.count == 1 }

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

    func testOutputPumpReadsBrokerOutputOffMainThread() throws {
        let runtime = NonMainOutputReadRuntime(payloads: [Data("background-output\n".utf8)])
        let fixture = try makeMidSessionFixture(runtime: runtime, channelID: "00000000-0000-0000-0000-000000008018")
        defer {
            fixture.terminal.detachBrokerSession()
            fixture.cleanup()
        }
        let outputHandled = expectation(description: "output handler called from broker output pump")
        outputHandled.expectedFulfillmentCount = 1
        fixture.terminal.setOutputHandler {
            XCTAssertTrue(Thread.isMainThread, "SwiftTerm feed/output handler must stay on the main thread")
            outputHandled.fulfill()
        }

        wait(for: [outputHandled], timeout: 1)

        XCTAssertFalse(runtime.didReadOnMainThread, "Broker output reads should run on the output read lane, not the main actor")
        XCTAssertFalse(
            runtime.didCheckLivenessOnMainThread,
            "Broker liveness and termination RPCs must run on the output lane, not the main actor"
        )
    }

    func testOutputPumpWakesFromBrokerAvailabilitySignalInsteadOfFixedFastPolling() throws {
        let runtime = SignaledOutputRuntime()
        let fixture = try makeMidSessionFixture(runtime: runtime, channelID: "00000000-0000-0000-0000-000000008019")
        defer {
            fixture.terminal.detachBrokerSession()
            fixture.cleanup()
        }
        let sessionID = try XCTUnwrap(fixture.terminal.brokerSessionID)
        var outputNotifications = 0
        fixture.terminal.setOutputHandler { outputNotifications += 1 }

        try waitUntil { runtime.readCount >= 1 }
        let readsAfterInitialWake = runtime.readCount
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(
            runtime.readCount,
            readsAfterInitialWake,
            "The output lane should stay idle without a fixed 20 ms polling timer"
        )

        runtime.triggerOutput("signaled-output\n", for: sessionID)

        try waitUntil { outputNotifications == 1 }
        XCTAssertGreaterThan(runtime.readCount, readsAfterInitialWake)
    }

    func testCancelledOutputSnapshotIsNotAcknowledgedBeforeTerminalDelivery() throws {
        let coordinator = BlockingReattachCoordinator()
        coordinator.blockOutputSnapshot()
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "delivery-cancellation",
            environmentProfile: .shell,
            coordinator: coordinator
        )
        terminal.startProcess(
            executable: "/bin/zsh",
            args: [],
            environment: nil,
            execName: nil,
            currentDirectory: "/tmp"
        )
        try waitUntil { terminal.brokerSessionID != nil }
        terminal.setOutputHandler {}
        XCTAssertTrue(coordinator.waitForOutputSnapshot())

        let detached = expectation(description: "terminal detached")
        terminal.detachBrokerSession { detached.fulfill() }
        coordinator.finishOutputSnapshot()
        wait(for: [detached], timeout: 1)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))

        XCTAssertEqual(coordinator.acknowledgedOutputGenerations, [])
        XCTAssertFalse(terminal.lastLines(5).joined(separator: "\n").contains("cancelled-before-delivery"))
    }

    func testQueuedOutputDeliveryIsRevokedWhenTeardownWinsMainActor() throws {
        let coordinator = BlockingReattachCoordinator()
        coordinator.blockOutputSnapshot()
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "queued-delivery-cancellation",
            environmentProfile: .shell,
            coordinator: coordinator
        )
        terminal.startProcess(
            executable: "/bin/zsh",
            args: [],
            environment: nil,
            execName: nil,
            currentDirectory: "/tmp"
        )
        try waitUntil { terminal.brokerSessionID != nil }
        terminal.setOutputHandler {}
        XCTAssertTrue(coordinator.waitForOutputSnapshot())

        let detached = expectation(description: "queued delivery terminal detached")
        DispatchQueue.main.async {
            terminal.detachBrokerSession { detached.fulfill() }
        }
        coordinator.finishOutputSnapshot()
        wait(for: [detached], timeout: 1)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))

        XCTAssertEqual(coordinator.acknowledgedOutputGenerations, [])
        XCTAssertFalse(terminal.lastLines(5).joined(separator: "\n").contains("cancelled-before-delivery"))
    }

    func testOldOutputLaneCannotCloseSameSessionIDAfterReattach() throws {
        let coordinator = BlockingReattachCoordinator()
        coordinator.blockOutputSnapshot()
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "same-id-output-generation",
            environmentProfile: .shell,
            coordinator: coordinator
        )
        terminal.startProcess(executable: "/bin/zsh", args: [], environment: nil, execName: nil, currentDirectory: "/tmp")
        try waitUntil { terminal.brokerSessionID != nil }
        let sessionID = try XCTUnwrap(terminal.brokerSessionID)
        terminal.setOutputHandler {}
        XCTAssertTrue(coordinator.waitForOutputSnapshot())

        let detached = expectation(description: "old output generation detached")
        terminal.detachBrokerSession { detached.fulfill() }
        wait(for: [detached], timeout: 1)
        terminal.startProcess(executable: "/bin/zsh", args: [], environment: nil, execName: nil, currentDirectory: "/tmp")
        XCTAssertTrue(coordinator.waitForReattach())
        coordinator.finishReattach()
        try waitUntil { !terminal.completesStartAsynchronously }

        coordinator.finishOutputSnapshot()
        try waitUntil { coordinator.outputReadCount >= 2 }

        XCTAssertEqual(terminal.brokerSessionID, sessionID)
        XCTAssertNil(terminal.sessionFailure)
        let cleanup = expectation(description: "replacement output generation detached")
        terminal.detachBrokerSession { cleanup.fulfill() }
        coordinator.finishOutputSnapshot()
        wait(for: [cleanup], timeout: 1)
    }

    func testOldInputFailureCannotCloseSameSessionIDAfterReattach() throws {
        let coordinator = BlockingReattachCoordinator()
        coordinator.blockNextInputWrite(fail: true)
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "same-id-input-generation",
            environmentProfile: .shell,
            coordinator: coordinator
        )
        terminal.startProcess(executable: "/bin/zsh", args: [], environment: nil, execName: nil, currentDirectory: "/tmp")
        try waitUntil { terminal.brokerSessionID != nil }
        let sessionID = try XCTUnwrap(terminal.brokerSessionID)
        terminal.send(Array("old-write".utf8))
        XCTAssertTrue(coordinator.waitForInputWrite())

        let detached = expectation(description: "old input generation detached")
        terminal.detachBrokerSession { detached.fulfill() }
        wait(for: [detached], timeout: 1)
        terminal.startProcess(executable: "/bin/zsh", args: [], environment: nil, execName: nil, currentDirectory: "/tmp")
        XCTAssertTrue(coordinator.waitForReattach())
        coordinator.finishReattach()
        try waitUntil { !terminal.completesStartAsynchronously }

        coordinator.finishInputWrite()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        XCTAssertEqual(terminal.brokerSessionID, sessionID)
        XCTAssertNil(terminal.sessionFailure)

        terminal.send(Array("replacement-write".utf8))
        try waitUntil { coordinator.successfulInputWrites == 1 }
        terminal.detachBrokerSession()
    }

    func testDelayedResizeFailureIsIgnoredAfterRunOwnershipIsRevoked() throws {
        let coordinator = BlockingReattachCoordinator()
        coordinator.blockNextResize(fail: true)
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "stale-resize-failure",
            environmentProfile: .shell,
            coordinator: coordinator
        )
        terminal.startProcess(executable: "/bin/zsh", args: [], environment: nil, execName: nil, currentDirectory: "/tmp")
        try waitUntil { terminal.brokerSessionID != nil }
        let sessionID = try XCTUnwrap(terminal.brokerSessionID)
        var failures: [TerminalSessionFailure] = []
        terminal.setSessionFailureHandler { failures.append($0) }

        terminal.resizeToCurrentGrid()
        XCTAssertTrue(coordinator.waitForResize())
        let detached = expectation(description: "resize owner detached")
        terminal.detachBrokerSession { detached.fulfill() }
        coordinator.finishResize()
        wait(for: [detached], timeout: 1)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))

        XCTAssertEqual(terminal.brokerSessionID, sessionID)
        XCTAssertNil(terminal.sessionFailure)
        XCTAssertTrue(failures.isEmpty)
    }

    func testOutputPumpDeliversFinalBytesBeforeReportingTermination() throws {
        let runtime = FinalOutputRuntime()
        let fixture = try makeMidSessionFixture(runtime: runtime, channelID: "00000000-0000-0000-0000-000000008020")
        defer { fixture.cleanup() }
        let sessionID = try XCTUnwrap(fixture.terminal.brokerSessionID)
        var events: [String] = []
        var outputLifecycles: [BrokerSessionLifecycle?] = []
        fixture.terminal.setOutputHandler {
            events.append("output")
            outputLifecycles.append(try? fixture.registry.load().first?.lifecycle)
        }
        fixture.terminal.setTerminationHandler { _ in events.append("termination") }

        runtime.triggerFinalOutput(
            "first-final-lane-output\n",
            afterTerminationCheck: "raced-final-lane-output\n",
            for: sessionID
        )

        try waitUntil { events.last == "termination" }
        XCTAssertEqual(events, ["output", "output", "termination"])
        XCTAssertEqual(outputLifecycles, [.running, .running], "Durable exit must follow delivery of the final drain")
        let finalLines = fixture.terminal.lastLines(5).joined(separator: "\n")
        XCTAssertTrue(finalLines.contains("first-final-lane-output"))
        XCTAssertTrue(finalLines.contains("raced-final-lane-output"))
        XCTAssertNil(fixture.terminal.brokerSessionID)
        XCTAssertEqual(try fixture.registry.load().single().lifecycle, .exited)
        XCTAssertTrue(
            try fixture.coordinator.reattachableSessions().isEmpty,
            "A naturally exited session must retire its runtime owner so closing the disconnected tab cannot resurrect it"
        )
    }

    func testOutputPumpDrainsEveryTransactionalChunkBeforeReportingTermination() throws {
        let runtime = FinalOutputRuntime(transactionalChunkSize: 8)
        let fixture = try makeMidSessionFixture(runtime: runtime, channelID: "00000000-0000-0000-0000-000000008021")
        defer { fixture.cleanup() }
        let sessionID = try XCTUnwrap(fixture.terminal.brokerSessionID)
        var events: [String] = []
        fixture.terminal.setOutputHandler { events.append("output") }
        fixture.terminal.setTerminationHandler { _ in events.append("termination") }

        runtime.triggerFinalOutput("chunk-01chunk-02chunk-03\n", for: sessionID)

        try waitUntil { events.last == "termination" }
        XCTAssertEqual(runtime.acknowledgedGenerations, [8, 16, 24, 25])
        XCTAssertEqual(events.last, "termination")
        XCTAssertTrue(fixture.terminal.lastLines(5).joined(separator: "\n").contains("chunk-01chunk-02chunk-03"))
        XCTAssertEqual(try runtime.listSessions(), [], "Runtime retirement must follow complete transactional drain")
    }

    func testTeardownAfterReplayDeliveryDoesNotReplaySameSessionAgain() throws {
        let coordinator = BlockingReattachCoordinator()
        coordinator.blockAcknowledgment()
        let sessionID = BrokerSessionID(rawValue: "replay-display-ownership")
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "replay-display-ownership",
            environmentProfile: .shell,
            existingBrokerSessionID: sessionID,
            coordinator: coordinator
        )

        terminal.startProcess(
            executable: "/bin/zsh",
            args: [],
            environment: nil,
            execName: nil,
            currentDirectory: "/tmp"
        )
        XCTAssertTrue(coordinator.waitForReattach())
        coordinator.finishReattach()
        try waitUntil { coordinator.acknowledgedOutputGenerations == [41] }
        XCTAssertEqual(coordinator.scrollbackSnapshotCount, 1)

        let detached = expectation(description: "detach after replay delivery")
        terminal.detachBrokerSession { detached.fulfill() }
        coordinator.finishAcknowledgment()
        wait(for: [detached], timeout: 1)

        terminal.startProcess(
            executable: "/bin/zsh",
            args: [],
            environment: nil,
            execName: nil,
            currentDirectory: "/tmp"
        )
        XCTAssertTrue(coordinator.waitForReattach())
        coordinator.finishReattach()
        try waitUntil { coordinator.reattachCallCount == 2 && !terminal.completesStartAsynchronously }

        XCTAssertEqual(
            coordinator.scrollbackSnapshotCount,
            1,
            "Presentation ownership must survive teardown even when acknowledgement completion becomes stale"
        )
        XCTAssertEqual(terminal.brokerSessionID, sessionID)
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
        try waitUntil { failures.count == 1 }

        runtime.isHostAvailable = true
        runtime.scrollbackTail = Data("already-rendered-before-host-loss".utf8)
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
        XCTAssertEqual(
            runtime.scrollbackTailReadCount,
            0,
            "Reattaching the same broker generation into the same terminal view must not replay already-rendered history"
        )
        XCTAssertNil(fixture.terminal.lastScrollbackReplay)
    }

    func testRetryAfterBrokerHostLossPublishesAuthoritativeReattachedWorkingDirectory() throws {
        let runtime = HostLossRuntime()
        let fixture = try makeMidSessionFixture(runtime: runtime, channelID: "00000000-0000-0000-0000-000000008019")
        defer { fixture.cleanup() }
        let sessionID = try XCTUnwrap(fixture.terminal.brokerSessionID)
        _ = try fixture.coordinator.updateWorkingDirectory(sessionID, to: "/tmp/live-broker-cwd")
        var reportedDirectories: [String?] = []
        fixture.terminal.setHostCurrentDirectoryHandler { reportedDirectories.append($0) }

        runtime.isHostAvailable = false
        fixture.terminal.pollOutputOnce()
        try waitUntil { fixture.terminal.sessionFailure != nil }
        runtime.isHostAvailable = true
        fixture.terminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh",
            currentDirectory: "/tmp/stale-channel-metadata"
        )

        XCTAssertEqual(reportedDirectories, ["/tmp/live-broker-cwd"])
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
        try waitUntil { failures.count == 1 }

        XCTAssertEqual(failures.map(\.kind), [.brokerSessionStale])
        XCTAssertNil(fixture.terminal.brokerSessionID, "A dropped session must not stay attached")
        XCTAssertEqual(fixture.terminal.staleBrokerSessionID, sessionID)
    }

    func testScrollbackPersistenceFailureRetiresSessionBeforeRetryCreatesReplacement() throws {
        let runtime = ScrollbackPersistenceFailureRuntime()
        let fixture = try makeMidSessionFixture(runtime: runtime, channelID: "00000000-0000-0000-0000-000000008021")
        defer { fixture.cleanup() }
        let failedSessionID = try XCTUnwrap(fixture.terminal.brokerSessionID)
        var failures: [TerminalSessionFailure] = []
        fixture.terminal.setSessionFailureHandler { failures.append($0) }

        fixture.terminal.pollOutputOnce()
        try waitUntil { failures.count == 1 }

        XCTAssertEqual(failures.map(\.kind), [.brokerSessionStale])
        XCTAssertEqual(runtime.retiredIDs, [failedSessionID])
        XCTAssertEqual(try fixture.registry.load().single().lifecycle, .errored)
        XCTAssertNil(fixture.terminal.brokerSessionID)
        XCTAssertEqual(fixture.terminal.staleBrokerSessionID, failedSessionID)

        fixture.terminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh",
            currentDirectory: "/tmp"
        )

        XCTAssertEqual(runtime.createdIDs.count, 2)
        XCTAssertNotEqual(runtime.createdIDs[1], failedSessionID)
        XCTAssertEqual(runtime.retiredIDs, [failedSessionID])
    }

    func testScrollbackPersistenceCleanupFailureKeepsHandleAndPreventsDuplicateRetry() throws {
        let runtime = ScrollbackPersistenceFailureRuntime()
        runtime.retirementError = RuntimeError.createFailed
        let fixture = try makeMidSessionFixture(runtime: runtime, channelID: "00000000-0000-0000-0000-000000008022")
        defer { fixture.cleanup() }
        let failedSessionID = try XCTUnwrap(fixture.terminal.brokerSessionID)
        var failures: [TerminalSessionFailure] = []
        fixture.terminal.setSessionFailureHandler { failures.append($0) }

        fixture.terminal.pollOutputOnce()
        try waitUntil { failures.count == 1 }

        XCTAssertEqual(failures.map(\.kind), [.failed])
        XCTAssertTrue(failures[0].description.contains("failed to retire persistence-broken broker session"))
        XCTAssertEqual(fixture.terminal.brokerSessionID, failedSessionID)
        XCTAssertNil(fixture.terminal.staleBrokerSessionID)
        XCTAssertTrue(runtime.retiredIDs.isEmpty)
        XCTAssertEqual(try fixture.registry.load().single().lifecycle, .running)

        fixture.terminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh",
            currentDirectory: "/tmp"
        )

        XCTAssertEqual(runtime.createdIDs, [failedSessionID])
        XCTAssertEqual(fixture.terminal.brokerSessionID, failedSessionID)
    }

    func testScrollbackPersistenceCompletedRetirementWarningClearsHandleBeforeReplacement() throws {
        let runtime = ScrollbackPersistenceFailureRuntime()
        let fixture = try makeMidSessionFixture(runtime: runtime, channelID: "00000000-0000-0000-0000-000000008024")
        defer { fixture.cleanup() }
        let failedSessionID = try XCTUnwrap(fixture.terminal.brokerSessionID)
        runtime.retirementError = NativePTYBrokerSessionRuntime.RuntimeError.retirementCompletedWithOutputFailure(
            failedSessionID,
            reason: "disk full"
        )
        var failures: [TerminalSessionFailure] = []
        fixture.terminal.setSessionFailureHandler { failures.append($0) }

        fixture.terminal.pollOutputOnce()
        try waitUntil { failures.count == 1 }

        XCTAssertEqual(failures.map(\.kind), [.brokerSessionStale])
        XCTAssertTrue(failures[0].description.contains("retirementCompletedWithOutputFailure"))
        XCTAssertEqual(runtime.retiredIDs, [failedSessionID])
        XCTAssertEqual(try fixture.registry.load().single().lifecycle, .errored)
        XCTAssertNil(fixture.terminal.brokerSessionID)
        XCTAssertEqual(fixture.terminal.staleBrokerSessionID, failedSessionID)

        fixture.terminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh",
            currentDirectory: "/tmp"
        )

        XCTAssertEqual(runtime.createdIDs.count, 2)
        XCTAssertNotEqual(runtime.createdIDs.last, failedSessionID)
    }

    func testScrollbackPersistenceRecoveryDoesNotBlockMainActor() throws {
        let runtime = ScrollbackPersistenceFailureRuntime()
        runtime.blocksRetirement = true
        let fixture = try makeMidSessionFixture(runtime: runtime, channelID: "00000000-0000-0000-0000-000000008023")
        defer { fixture.cleanup() }
        var failures: [TerminalSessionFailure] = []
        fixture.terminal.setSessionFailureHandler { failures.append($0) }

        let started = Date()
        fixture.terminal.pollOutputOnce()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.05, "Persistence recovery must leave the main actor without waiting for broker retirement")
        try waitUntil {
            runtime.waitForRetirement(timeout: 0.01)
        }
        XCTAssertTrue(failures.isEmpty, "Failure truth is not final until retirement completes")

        runtime.unblockRetirement()
        try waitUntil { failures.count == 1 }
        XCTAssertEqual(failures.map(\.kind), [.brokerSessionStale])
    }

    func testRetryRetiresUntrackedGenerationOffMainBeforeReplacement() throws {
        let runtime = BlockingUntrackedRetirementRuntime()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerBackedTerminalUntrackedTests-")
            .appendingPathComponent(UUID().uuidString)
        let blocker = parent.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: parent) }
        let coordinator = BrokerSessionCoordinator(
            registry: BrokerSessionRegistry(fileURL: blocker.appendingPathComponent("sessions.json")),
            runtime: runtime
        )
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "untracked",
            environmentProfile: .shell,
            coordinator: coordinator
        )

        terminal.startProcess(executable: "/bin/zsh", args: [], environment: nil, execName: "zsh", currentDirectory: "/tmp")
        let untrackedID = try XCTUnwrap(terminal.untrackedBrokerSessionID)

        let started = Date()
        terminal.startProcess(executable: "/bin/zsh", args: [], environment: nil, execName: "zsh", currentDirectory: "/tmp")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05)
        XCTAssertTrue(runtime.waitForRetirement(), "Retry must begin retirement on the recovery lane")
        XCTAssertEqual(terminal.untrackedBrokerSessionID, untrackedID)
        XCTAssertTrue(terminal.completesStartAsynchronously)

        runtime.unblockRetirement()
        try waitUntil { !terminal.completesStartAsynchronously }
        XCTAssertNil(terminal.untrackedBrokerSessionID)
        XCTAssertEqual(runtime.retirementAttempts, [untrackedID, untrackedID])
        XCTAssertEqual(runtime.createdIDs, [untrackedID], "Replacement cannot start before the old generation is retired")
    }

    func testTeardownRetiresRememberedUntrackedGeneration() throws {
        let runtime = BlockingUntrackedRetirementRuntime()
        runtime.unblockRetirement()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerBackedTerminalUntrackedTeardownTests-")
            .appendingPathComponent(UUID().uuidString)
        let blocker = parent.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: parent) }
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "untracked",
            environmentProfile: .shell,
            coordinator: BrokerSessionCoordinator(
                registry: BrokerSessionRegistry(fileURL: blocker.appendingPathComponent("sessions.json")),
                runtime: runtime
            )
        )

        terminal.startProcess(executable: "/bin/zsh", args: [], environment: nil, execName: "zsh", currentDirectory: "/tmp")
        let untrackedID = try XCTUnwrap(terminal.untrackedBrokerSessionID)
        terminal.detachBrokerSession()

        try waitUntil { terminal.untrackedBrokerSessionID == nil }
        XCTAssertEqual(runtime.retirementAttempts, [untrackedID, untrackedID])
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
            args: ["-c", "printf '\\033]7;file://localhost/tmp\\007'; sleep 0.1"],
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
        XCTAssertNil(terminal.brokerSessionID, "An exited process must release its live handle before retry")

        terminal.startProcess(
            executable: "/bin/cat",
            args: [],
            environment: nil,
            execName: "cat",
            currentDirectory: "/tmp"
        )
        let replacementID = try XCTUnwrap(terminal.brokerSessionID)
        defer { _ = try? coordinator.markErrored(replacementID) }
        XCTAssertNotEqual(replacementID, exited.id, "Retry after normal exit must spawn a replacement process")
        XCTAssertEqual(try registry.load().filter { $0.lifecycle == .running }.map(\.id), [replacementID])
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

    func testDetachInvalidatesPendingReattachCompletion() throws {
        let sessionID = BrokerSessionID(rawValue: "pending-reattach")
        let coordinator = BlockingReattachCoordinator()
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(uuidString: "00000000-0000-0000-0000-000000008021")!,
            channelType: .agentDirect,
            label: "agent",
            environmentProfile: .agentOAuth,
            existingBrokerSessionID: sessionID,
            coordinator: coordinator
        )
        var completionCount = 0
        terminal.setStartCompletionHandler { completionCount += 1 }

        terminal.startProcess(
            executable: "/usr/bin/env",
            args: ["codex"],
            environment: nil,
            execName: "codex",
            currentDirectory: "/tmp"
        )
        XCTAssertTrue(coordinator.waitForReattach())
        terminal.startProcess(
            executable: "/usr/bin/env",
            args: ["codex"],
            environment: nil,
            execName: "codex",
            currentDirectory: "/tmp"
        )
        terminal.detachBrokerSession()
        coordinator.finishReattach()
        XCTAssertTrue(coordinator.waitForReattachReturn())
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))

        XCTAssertEqual(coordinator.detachCalls, [sessionID])
        XCTAssertEqual(coordinator.reattachCallCount, 1, "Retry must not enqueue a competing reattach")
        XCTAssertFalse(terminal.completesStartAsynchronously)
        XCTAssertEqual(completionCount, 0)
        XCTAssertNil(terminal.agentStatusOwnerToken, "A completion after detach must not reactivate the session")
    }

    func testRestoredSessionDoesNotConsumeOutputBeforeReattachCommits() throws {
        let sessionID = BrokerSessionID(rawValue: "pending-output-reattach")
        let coordinator = BlockingReattachCoordinator()
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "restored",
            environmentProfile: .shell,
            existingBrokerSessionID: sessionID,
            coordinator: coordinator
        )
        terminal.setOutputHandler {}
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        XCTAssertEqual(coordinator.outputReadCount, 0)

        terminal.startProcess(executable: "/bin/zsh", args: [], environment: nil, execName: "zsh", currentDirectory: "/tmp")
        XCTAssertTrue(coordinator.waitForReattach())
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        XCTAssertEqual(coordinator.outputReadCount, 0, "Live output must not be drained ahead of replay")

        coordinator.finishReattach()
        try waitUntil { !terminal.completesStartAsynchronously }
        try waitUntil { coordinator.outputReadCount > 0 }
        terminal.detachBrokerSession()
    }

    func testTrackedTeardownBrokerRPCDoesNotBlockMainActor() throws {
        let sessionID = BrokerSessionID(rawValue: "tracked-teardown")
        let coordinator = BlockingReattachCoordinator()
        coordinator.blockTeardown()
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "tracked",
            environmentProfile: .shell,
            existingBrokerSessionID: sessionID,
            coordinator: coordinator
        )

        let started = Date()
        terminal.detachBrokerSession()

        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05)
        XCTAssertTrue(coordinator.waitForTeardown())
        XCTAssertEqual(coordinator.teardownRanOnMainThread, [false])
        coordinator.finishTeardown()
    }

    func testFreshStartBrokerRPCDoesNotBlockMainActor() throws {
        let coordinator = BlockingReattachCoordinator()
        coordinator.blockStart()
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "new",
            environmentProfile: .shell,
            coordinator: coordinator
        )

        let started = Date()
        terminal.startProcess(executable: "/bin/zsh", args: [], environment: nil, execName: "zsh", currentDirectory: "/tmp")

        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05)
        XCTAssertTrue(terminal.completesStartAsynchronously)
        XCTAssertTrue(coordinator.waitForStart())
        XCTAssertEqual(coordinator.startRanOnMainThread, [false])
        coordinator.finishStart()
        try waitUntil { !terminal.completesStartAsynchronously }
        XCTAssertEqual(terminal.brokerOwnedSessionID, BrokerSessionID(rawValue: "started-off-main"))
    }

    func testProductionResizeBrokerRPCDoesNotBlockMainActor() throws {
        let coordinator = BlockingReattachCoordinator()
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "resize",
            environmentProfile: .shell,
            coordinator: coordinator
        )
        terminal.startProcess(executable: "/bin/zsh", args: [], environment: nil, execName: "zsh", currentDirectory: "/tmp")
        try waitUntil { !terminal.completesStartAsynchronously }
        coordinator.blockResize()

        let started = Date()
        terminal.resizeToCurrentGrid()

        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05)
        XCTAssertTrue(coordinator.waitForResize())
        XCTAssertEqual(coordinator.resizeRanOnMainThread, [false])
        coordinator.finishResize()
    }

    func testUntrackedRetryWaitsForOffMainReplacementBeforeCompletingStart() throws {
        let coordinator = BlockingReattachCoordinator()
        coordinator.untrackedStartID = BrokerSessionID(rawValue: "untracked-retry")
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "retry",
            environmentProfile: .shell,
            coordinator: coordinator
        )
        var completionCount = 0
        terminal.setStartCompletionHandler { completionCount += 1 }
        terminal.startProcess(executable: "/bin/zsh", args: [], environment: nil, execName: "zsh", currentDirectory: "/tmp")
        try waitUntil { terminal.untrackedBrokerSessionID != nil }
        XCTAssertEqual(completionCount, 1)

        coordinator.untrackedStartID = nil
        coordinator.blockStart()
        terminal.startProcess(executable: "/bin/zsh", args: [], environment: nil, execName: "zsh", currentDirectory: "/tmp")
        try waitUntil { coordinator.startCallCount == 2 }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        XCTAssertTrue(terminal.completesStartAsynchronously)
        XCTAssertEqual(completionCount, 1, "Retirement is not the replacement start commit point")
        XCTAssertNil(terminal.brokerOwnedSessionID)

        coordinator.finishStart()
        try waitUntil { !terminal.completesStartAsynchronously }
        XCTAssertEqual(completionCount, 2)
        XCTAssertEqual(terminal.brokerOwnedSessionID, BrokerSessionID(rawValue: "started-off-main"))
    }

    func testTeardownWaitsForPendingFreshStartAndRetiresItsSession() throws {
        let coordinator = BlockingReattachCoordinator()
        coordinator.blockStart()
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "new",
            environmentProfile: .shell,
            coordinator: coordinator
        )
        terminal.startProcess(executable: "/bin/zsh", args: [], environment: nil, execName: "zsh", currentDirectory: "/tmp")
        XCTAssertTrue(coordinator.waitForStart())
        var teardownCompleted = false

        terminal.detachBrokerSession {
            teardownCompleted = true
        }

        XCTAssertFalse(teardownCompleted)
        coordinator.finishStart()
        try waitUntil { teardownCompleted }
        XCTAssertEqual(coordinator.markErroredCalls, [BrokerSessionID(rawValue: "started-off-main")])
        XCTAssertNil(terminal.brokerOwnedSessionID)
    }

    func testReconnectDuringCancelledFreshStartCleanupRunsAfterRetirement() throws {
        let coordinator = BlockingReattachCoordinator()
        coordinator.blockStart()
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "new",
            environmentProfile: .shell,
            coordinator: coordinator
        )
        var completionCount = 0
        var teardownCompleted = false
        terminal.setStartCompletionHandler { completionCount += 1 }

        terminal.startProcess(executable: "/bin/zsh", args: [], environment: nil, execName: "zsh", currentDirectory: "/tmp/original")
        XCTAssertTrue(coordinator.waitForStart())
        terminal.detachBrokerSession { teardownCompleted = true }

        // A denied quit can reopen reconnect while teardown still owns the
        // cancelled launch. The retry must wait for retirement, not disappear.
        terminal.startProcess(executable: "/bin/zsh", args: [], environment: nil, execName: "zsh", currentDirectory: "/tmp/retry")
        XCTAssertTrue(terminal.completesStartAsynchronously)
        coordinator.finishStart()

        try waitUntil { teardownCompleted }
        XCTAssertTrue(coordinator.waitForStart(), "Reconnect was not started after cancelled-session retirement")
        XCTAssertEqual(completionCount, 0)
        coordinator.finishStart()

        try waitUntil { !terminal.completesStartAsynchronously }
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(terminal.brokerOwnedSessionID, BrokerSessionID(rawValue: "started-off-main"))
        XCTAssertEqual(coordinator.startCallCount, 2)
    }

    func testSecondTeardownRevokesReconnectQueuedBehindCancelledFreshStart() throws {
        let coordinator = BlockingReattachCoordinator()
        coordinator.blockStart()
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "new",
            environmentProfile: .shell,
            coordinator: coordinator
        )
        var startCompletionCount = 0
        var teardownCompletionCount = 0
        terminal.setStartCompletionHandler { startCompletionCount += 1 }

        terminal.startProcess(executable: "/bin/zsh", args: [], environment: nil, execName: "zsh", currentDirectory: "/tmp/original")
        XCTAssertTrue(coordinator.waitForStart())
        terminal.detachBrokerSession { teardownCompletionCount += 1 }
        terminal.startProcess(executable: "/bin/zsh", args: [], environment: nil, execName: "zsh", currentDirectory: "/tmp/retry")

        // A second quit owns final termination authority. It must cancel the
        // reconnect queued after the first quit was denied.
        terminal.detachBrokerSession { teardownCompletionCount += 1 }
        coordinator.finishStart()

        try waitUntil { teardownCompletionCount == 2 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(coordinator.startCallCount, 1, "No replacement may launch after the second teardown completes")
        XCTAssertEqual(startCompletionCount, 0)
        XCTAssertFalse(terminal.completesStartAsynchronously)
        XCTAssertNil(terminal.brokerOwnedSessionID)
    }

    func testUntrackedTeardownBrokerRPCDoesNotBlockMainActor() throws {
        let sessionID = BrokerSessionID(rawValue: "untracked-teardown")
        let coordinator = BlockingReattachCoordinator()
        coordinator.untrackedStartID = sessionID
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "untracked",
            environmentProfile: .shell,
            coordinator: coordinator
        )
        terminal.startProcess(executable: "/bin/zsh", args: [], environment: nil, execName: "zsh", currentDirectory: "/tmp")
        try waitUntil { terminal.untrackedBrokerSessionID == sessionID }
        coordinator.blockTeardown()

        let started = Date()
        terminal.detachBrokerSession()

        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05)
        XCTAssertTrue(coordinator.waitForTeardown())
        XCTAssertEqual(coordinator.teardownRanOnMainThread, [false])
        coordinator.finishTeardown()
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

    func testExitedDetachedSessionReplaysFinalScrollbackBeforePublishingExit() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerBackedTerminalExitedReplayTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let runtime = NativePTYBrokerSessionRuntime()
        let coordinator = BrokerSessionCoordinator(registry: registry, runtime: runtime)
        let original = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/bin/sh",
                arguments: ["-c", "sleep 0.05; printf detached-final-scrollback; exit 7"],
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .shell,
            label: "finished-shell",
            attachedChannelID: UUID()
        )
        _ = try coordinator.detach(original.id)
        try waitUntil { try coordinator.terminationStatus(original.id) == 7 }

        let recoverable = try coordinator.reattachableSessions()
        XCTAssertEqual(recoverable.map(\.id), [original.id])
        XCTAssertEqual(recoverable.first?.lifecycle, .exited)

        let restoredTerminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "finished-shell",
            environmentProfile: .shell,
            existingBrokerSessionID: original.id,
            coordinator: coordinator
        )
        var events: [String] = []
        restoredTerminal.setOutputHandler { events.append("output") }
        restoredTerminal.setTerminationHandler { exitCode in events.append("exit:\(exitCode ?? -1)") }
        restoredTerminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh",
            currentDirectory: "/tmp"
        )

        try waitUntil { events.contains("exit:7") }
        XCTAssertEqual(events.first, "output", "Final replay must render before exit authority reaches the controller")
        XCTAssertEqual(events.last, "exit:7")
        XCTAssertTrue(restoredTerminal.lastLines(20).joined(separator: "\n").contains("detached-final-scrollback"))
        XCTAssertNil(restoredTerminal.brokerSessionID)
        XCTAssertEqual(try registry.load().single().lifecycle, .exited)
        XCTAssertEqual(try runtime.listSessions(), [], "Completed runtime ownership must retire after final replay")
    }

    func testExitedDetachedSessionDrainsUnreadOutputWhenReplayCannotContainGenerationBeforeExit() throws {
        let coordinator = ExitedUnreadOutputCoordinator()
        let restoredTerminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "oversized-finished-shell",
            environmentProfile: .shell,
            existingBrokerSessionID: coordinator.sessionID,
            coordinator: coordinator
        )
        var events: [String] = []
        restoredTerminal.setOutputHandler { events.append("output") }
        restoredTerminal.setTerminationHandler { exitCode in events.append("exit:\(exitCode ?? -1)") }

        restoredTerminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh",
            currentDirectory: "/tmp"
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))

        XCTAssertEqual(coordinator.outputReadCount, 3)
        XCTAssertEqual(coordinator.acknowledgedGenerations, [24, 48])
        XCTAssertEqual(coordinator.retiredSessionIDs, [coordinator.sessionID])
        XCTAssertEqual(events.first, "output", "Preserved unread bytes must render before exit authority")
        XCTAssertEqual(events.last, "exit:9")
        XCTAssertEqual(restoredTerminal.lastScrollbackReplay?.data, Data(), "Oversized unread generation must remain owned by the final drain")
        let finalLines = restoredTerminal.lastLines(20).joined(separator: "\n")
        XCTAssertTrue(finalLines.contains("detached-final-chunk-one"))
        XCTAssertTrue(finalLines.contains("detached-final-chunk-two"))
        XCTAssertNil(restoredTerminal.brokerSessionID)
    }

    func testAmbiguousExitedSessionDrainsFinalOutputBeforePublishingObservedExit() throws {
        let coordinator = ExitedUnreadOutputCoordinator()
        coordinator.restoredLifecycle = .exiting
        let restoredTerminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "ambiguous-finished-shell",
            environmentProfile: .shell,
            existingBrokerSessionID: coordinator.sessionID,
            coordinator: coordinator
        )
        var events: [String] = []
        restoredTerminal.setOutputHandler { events.append("output") }
        restoredTerminal.setTerminationHandler { exitCode in events.append("exit:\(exitCode ?? -1)") }

        restoredTerminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh",
            currentDirectory: "/tmp"
        )

        try waitUntil { events.contains("exit:9") }
        XCTAssertEqual(coordinator.finalizedExitCodes, [9])
        XCTAssertEqual(coordinator.acknowledgedGenerations, [24, 48])
        XCTAssertEqual(events.first, "output")
        XCTAssertEqual(events.last, "exit:9")
        let finalLines = restoredTerminal.lastLines(20).joined(separator: "\n")
        XCTAssertTrue(finalLines.contains("detached-final-chunk-one"))
        XCTAssertTrue(finalLines.contains("detached-final-chunk-two"))
        XCTAssertNil(restoredTerminal.brokerSessionID)
    }

    func testNaturalExitPublishesTerminationThenDescriptorCloseWarning() throws {
        let coordinator = ExitedUnreadOutputCoordinator()
        coordinator.restoredLifecycle = .exiting
        coordinator.finalizationError = NativePTYBrokerSessionRuntime.RuntimeError
            .exitCompletedWithInputCloseFailure(
                coordinator.sessionID,
                observedExitCode: 9,
                inputCloseErrno: EIO,
                expectedExitCode: 9
            )
        coordinator.terminationStatusError = NativePTYBrokerSessionRuntime.RuntimeError
            .exitCompletedWithInputCloseFailure(
                coordinator.sessionID,
                observedExitCode: 9,
                inputCloseErrno: EIO,
                expectedExitCode: nil
            )
        coordinator.retirementError = NativePTYBrokerSessionRuntime.RuntimeError
            .retirementCompletedWithInputCloseFailure(coordinator.sessionID, errno: EIO)
        let restoredTerminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "completed-close-warning",
            environmentProfile: .shell,
            existingBrokerSessionID: coordinator.sessionID,
            coordinator: coordinator
        )
        var events: [String] = []
        var failures: [TerminalSessionFailure] = []
        restoredTerminal.setOutputHandler { events.append("output") }
        restoredTerminal.setSessionFailureHandler { failures.append($0) }
        restoredTerminal.setTerminationHandler { exitCode in events.append("exit:\(exitCode ?? -1)") }

        restoredTerminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh",
            currentDirectory: "/tmp"
        )

        try waitUntil { events.contains("exit:9") && failures.count == 1 }
        XCTAssertEqual(events.first, "output")
        XCTAssertTrue(failures[0].description.contains("exitCompletedWithInputCloseFailure"))
        XCTAssertNil(restoredTerminal.brokerSessionID)
    }

    func testRestoredExitPublishesTerminationAfterCompletedRetirementWarning() throws {
        let coordinator = ExitedUnreadOutputCoordinator()
        coordinator.retirementError = BrokerSessionHostClientRuntime.ClientError.hostFailure(
            code: "retirement-completed-with-input-close-failure",
            message: "descriptor close reported EIO after completed retirement"
        )
        let restoredTerminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "restored-completed-close-warning",
            environmentProfile: .shell,
            existingBrokerSessionID: coordinator.sessionID,
            coordinator: coordinator
        )
        var exits: [Int32?] = []
        var failures: [TerminalSessionFailure] = []
        restoredTerminal.setOutputHandler {}
        restoredTerminal.setSessionFailureHandler { failures.append($0) }
        restoredTerminal.setTerminationHandler { exits.append($0) }

        restoredTerminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh",
            currentDirectory: "/tmp"
        )

        try waitUntil { exits == [9] && failures.count == 1 }
        XCTAssertTrue(failures[0].description.contains("retirement-completed-with-input-close-failure"))
        XCTAssertNil(restoredTerminal.brokerSessionID)
    }

    func testRecoveredExitedMismatchPublishesFailureAndRetiresRuntimeAfterFinalOutput() throws {
        let coordinator = ExitedUnreadOutputCoordinator()
        coordinator.requestedExitCode = 0
        let restoredTerminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "mismatched-finished-shell",
            environmentProfile: .shell,
            existingBrokerSessionID: coordinator.sessionID,
            coordinator: coordinator
        )
        var events: [String] = []
        var failures: [TerminalSessionFailure] = []
        restoredTerminal.setOutputHandler { events.append("output") }
        restoredTerminal.setSessionFailureHandler { failures.append($0) }
        restoredTerminal.setTerminationHandler { exitCode in events.append("exit:\(exitCode ?? -1)") }

        restoredTerminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh",
            currentDirectory: "/tmp"
        )

        try waitUntil { events.contains("exit:9") && failures.count == 1 }
        XCTAssertEqual(coordinator.retiredSessionIDs, [coordinator.sessionID])
        XCTAssertEqual(failures.map(\.kind), [.failed])
        XCTAssertTrue(failures.first?.description.contains("exitCodeMismatch") == true)
        XCTAssertEqual(events.first, "output")
        XCTAssertNil(restoredTerminal.brokerSessionID)
    }

    func testAmbiguousExitMismatchRetiresRuntimeBeforePublishingFailure() throws {
        let coordinator = ExitedUnreadOutputCoordinator()
        coordinator.restoredLifecycle = .exiting
        coordinator.requestedExitCode = 0
        coordinator.finalizationError = BrokerSessionCoordinator.CoordinatorError.exitCodeMismatch(
            coordinator.sessionID,
            expected: 0,
            observed: 9
        )
        let restoredTerminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "mismatched-ambiguous-shell",
            environmentProfile: .shell,
            existingBrokerSessionID: coordinator.sessionID,
            coordinator: coordinator
        )
        var exits: [Int32?] = []
        var failures: [TerminalSessionFailure] = []
        restoredTerminal.setOutputHandler {}
        restoredTerminal.setSessionFailureHandler { failures.append($0) }
        restoredTerminal.setTerminationHandler { exits.append($0) }

        restoredTerminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh",
            currentDirectory: "/tmp"
        )

        try waitUntil { exits == [9] && failures.count == 1 }
        XCTAssertEqual(coordinator.retiredSessionIDs, [coordinator.sessionID])
        XCTAssertEqual(failures.map(\.kind), [.failed])
        XCTAssertNil(restoredTerminal.brokerSessionID)
    }

    func testAmbiguousExitMismatchRemainsObservableWhenRuntimeRetirementFails() throws {
        let coordinator = ExitedUnreadOutputCoordinator()
        coordinator.restoredLifecycle = .exiting
        coordinator.requestedExitCode = 0
        coordinator.finalizationError = BrokerSessionCoordinator.CoordinatorError.exitCodeMismatch(
            coordinator.sessionID,
            expected: 0,
            observed: 9
        )
        coordinator.retirementError = RuntimeError.createFailed
        let restoredTerminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "mismatched-retirement-failure",
            environmentProfile: .shell,
            existingBrokerSessionID: coordinator.sessionID,
            coordinator: coordinator
        )
        var failures: [TerminalSessionFailure] = []
        var exits: [Int32?] = []
        restoredTerminal.setOutputHandler {}
        restoredTerminal.setSessionFailureHandler { failures.append($0) }
        restoredTerminal.setTerminationHandler { exits.append($0) }

        restoredTerminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh",
            currentDirectory: "/tmp"
        )

        try waitUntil { failures.count == 1 }
        XCTAssertTrue(failures[0].description.contains("exitCodeMismatch"))
        XCTAssertTrue(failures[0].description.contains("createFailed"))
        XCTAssertEqual(restoredTerminal.brokerSessionID, coordinator.sessionID)
        XCTAssertTrue(exits.isEmpty)
    }

    func testExitedFinalDrainDoesNotRetireAfterTeardownRevokesDelivery() throws {
        let coordinator = ExitedUnreadOutputCoordinator()
        coordinator.blockOutputRead()
        let restoredTerminal = BrokerBackedTerminalProcess(
            channelID: UUID(),
            channelType: .shell,
            label: "cancelled-finished-shell",
            environmentProfile: .shell,
            existingBrokerSessionID: coordinator.sessionID,
            coordinator: coordinator
        )
        var events: [String] = []
        restoredTerminal.setOutputHandler { events.append("output") }
        restoredTerminal.setTerminationHandler { exitCode in events.append("exit:\(exitCode ?? -1)") }

        restoredTerminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh",
            currentDirectory: "/tmp"
        )
        try waitUntil { coordinator.outputReadCount == 1 }

        let detached = expectation(description: "exited delivery terminal detached")
        DispatchQueue.main.async {
            restoredTerminal.detachBrokerSession { detached.fulfill() }
        }
        coordinator.finishOutputRead()
        wait(for: [detached], timeout: 1)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))

        XCTAssertEqual(coordinator.retiredSessionIDs, [])
        XCTAssertEqual(events, [])
        XCTAssertFalse(restoredTerminal.lastLines(20).joined(separator: "\n").contains("detached-final-overflow"))
        XCTAssertEqual(restoredTerminal.brokerSessionID, coordinator.sessionID)
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
