import Foundation

/// Request dispatcher for the out-of-process broker host protocol.
///
/// The host owns a `BrokerSessionRuntime`, accepts one newline-delimited request
/// frame, and returns one newline-delimited response frame. It intentionally
/// keeps runtime errors inside protocol failure frames so the app-side client can
/// fail loudly with a broker-specific message instead of losing the connection
/// context.
struct BrokerSessionHost {
    private enum RequestError: Error {
        case expiredBeforeDispatch
    }

    private let runtime: any BrokerSessionRuntime
    private let codec: BrokerSessionHostCodec
    private let scheduler: BrokerSessionOperationScheduler

    init(
        runtime: any BrokerSessionRuntime,
        codec: BrokerSessionHostCodec = BrokerSessionHostCodec(),
        scheduler: BrokerSessionOperationScheduler = BrokerSessionOperationScheduler()
    ) {
        self.runtime = runtime
        self.codec = codec
        self.scheduler = scheduler
    }

    func handle(
        _ frame: Data,
        executionIsAllowed: () -> Bool = { true }
    ) throws -> Data {
        let request = try codec.decodeRequest(frame)
        let response: BrokerSessionHostResponse
        do {
            response = try scheduler.perform(request) {
                guard executionIsAllowed() else {
                    throw RequestError.expiredBeforeDispatch
                }
                return try dispatch(request)
            }
        } catch {
            response = .failure(
                BrokerSessionHostFailure(
                    code: failureCode(for: error),
                    message: String(describing: error)
                )
            )
        }
        return try codec.encodeResponse(response)
    }

    private func dispatch(_ request: BrokerSessionHostRequest) throws -> BrokerSessionHostResponse {
        switch request {
        case .listSessions:
            return .sessionIDs(try runtime.listSessions())
        case let .create(id, launchRequest):
            guard launchRequest.agentStatusOwnerToken != nil else {
                try runtime.createSession(id: id, request: launchRequest)
                return .ok
            }
            if let acknowledgingRuntime = runtime as? BrokerSessionAgentStatusOwnerTokenAcknowledgingRuntime {
                let applied = try acknowledgingRuntime.createSessionAcknowledgingAgentStatusOwnerToken(
                    id: id,
                    request: launchRequest
                )
                return .created(agentStatusOwnerTokenApplied: applied)
            }
            try runtime.createSession(id: id, request: launchRequest)
            return .created(agentStatusOwnerTokenApplied: false)
        case let .detach(id):
            try runtime.detachSession(id: id)
            return .ok
        case let .attach(id, channelID):
            try runtime.attachSession(id: id, channelID: channelID)
            return .ok
        case let .terminate(id, exitCode):
            try runtime.terminateSession(id: id, exitCode: exitCode)
            return .ok
        case let .markErrored(id):
            try runtime.markSessionErrored(id: id)
            return .ok
        case let .sendInput(id, bytes):
            try runtime.sendInput(id: id, bytes: Array(bytes))
            return .ok
        case let .snapshotAvailableOutput(id, maxBytes):
            guard let transactionalRuntime = runtime as? BrokerTransactionalOutputRuntime else {
                throw BrokerTransactionalOutputRequiredError()
            }
            return .outputSnapshot(
                try transactionalRuntime.snapshotAvailableOutput(
                    id: id,
                    maxBytes: max(0, min(maxBytes, BrokerSessionHostProtocolLimits.maximumOutputPayloadSize))
                )
            )
        case let .waitForOutputAvailability(id, timeoutMilliseconds):
            return .outputAvailable(try waitForOutputAvailability(id: id, timeoutMilliseconds: timeoutMilliseconds))
        case let .readScrollbackTail(id, maxBytes):
            return .output(try runtime.readScrollbackTail(id: id, maxBytes: maxBytes))
        case let .snapshotScrollbackReplay(id, maxBytes):
            if let transactionalRuntime = runtime as? BrokerTransactionalOutputRuntime {
                return .scrollbackReplaySnapshot(
                    try transactionalRuntime.snapshotScrollbackReplay(id: id, maxBytes: maxBytes)
                )
            }
            // Non-consuming tails have no unread-output watermark. Return no
            // replay rather than duplicating bytes when the live pump starts.
            // Preserve tail-read errors so clients can report corrupt storage.
            _ = try runtime.readScrollbackTail(id: id, maxBytes: maxBytes)
            return .scrollbackReplay(
                ScrollbackReplay(
                    data: Data(),
                    source: .unknown,
                    maxBytes: maxBytes
                )
            )
        case let .acknowledgeOutput(id, generation):
            guard let transactionalRuntime = runtime as? BrokerTransactionalOutputRuntime else {
                throw BrokerTransactionalOutputRequiredError()
            }
            try transactionalRuntime.acknowledgeOutput(id: id, through: generation)
            return .ok
        case let .resize(id, size):
            try runtime.resizeSession(id: id, size: size)
            return .ok
        case let .isRunning(id):
            return .running(try runtime.isRunning(id: id))
        case let .terminationStatus(id):
            return .terminationStatus(try runtime.terminationStatus(id: id))
        }
    }

    private func waitForOutputAvailability(id: BrokerSessionID, timeoutMilliseconds: Int) throws -> Bool {
        guard let runtime = runtime as? BrokerOutputAvailabilityMonitoringRuntime else {
            return false
        }
        let semaphore = DispatchSemaphore(value: 0)
        try runtime.setOutputAvailabilityHandler(id: id) { signaledID in
            guard signaledID == id else { return }
            semaphore.signal()
        }
        defer { try? runtime.setOutputAvailabilityHandler(id: id, handler: nil) }

        let boundedTimeout = max(0, min(timeoutMilliseconds, 5_000))
        return semaphore.wait(timeout: .now() + .milliseconds(boundedTimeout)) == .success
    }

    private func failureCode(for error: Error) -> String {
        if case NativePTYBrokerSessionRuntime.RuntimeError.missingSession = error {
            return "missing-session"
        }
        if case NativePTYBrokerSessionRuntime.RuntimeError.scrollbackPersistenceFailed = error {
            return "scrollback-persistence-failed"
        }
        return "runtime-error"
    }
}

final class BrokerSessionOperationScheduler: @unchecked Sendable {
    private final class Lane {
        let queue: DispatchQueue
        var admittedOperationCount = 0

        init(sessionID: BrokerSessionID) {
            self.queue = DispatchQueue(label: "holoscape.broker.session.\(sessionID.rawValue)")
        }
    }

    private let lock = NSLock()
    private var lanes: [BrokerSessionID: Lane] = [:]

    var activeLaneCount: Int {
        lock.withLock { lanes.count }
    }

    func admittedOperationCount(for sessionID: BrokerSessionID) -> Int {
        lock.withLock { lanes[sessionID]?.admittedOperationCount ?? 0 }
    }

    func perform<T>(_ request: BrokerSessionHostRequest, operation: () throws -> T) throws -> T {
        guard let sessionID = request.sessionOrderingID else {
            return try operation()
        }
        let lane = admitOperation(for: sessionID)
        defer { releaseOperation(for: sessionID, from: lane) }
        return try lane.queue.sync(execute: operation)
    }

    private func admitOperation(for sessionID: BrokerSessionID) -> Lane {
        lock.withLock {
            let lane: Lane
            if let existingLane = lanes[sessionID] {
                lane = existingLane
            } else {
                lane = Lane(sessionID: sessionID)
                lanes[sessionID] = lane
            }
            lane.admittedOperationCount += 1
            return lane
        }
    }

    private func releaseOperation(for sessionID: BrokerSessionID, from lane: Lane) {
        lock.withLock {
            precondition(lane.admittedOperationCount > 0)
            lane.admittedOperationCount -= 1
            guard lane.admittedOperationCount == 0,
                  lanes[sessionID] === lane else {
                return
            }
            lanes.removeValue(forKey: sessionID)
        }
    }
}

private extension BrokerSessionHostRequest {
    var sessionOrderingID: BrokerSessionID? {
        switch self {
        case .listSessions:
            return nil
        case let .create(id, _),
             let .detach(id),
             let .attach(id, _),
             let .terminate(id, _),
             let .markErrored(id),
             let .sendInput(id, _),
             let .snapshotAvailableOutput(id, _),
             let .waitForOutputAvailability(id, _),
             let .readScrollbackTail(id, _),
             let .snapshotScrollbackReplay(id, _),
             let .acknowledgeOutput(id, _),
             let .resize(id, _),
             let .isRunning(id),
             let .terminationStatus(id):
            return id
        }
    }
}

private struct BrokerTransactionalOutputRequiredError: Error, CustomStringConvertible {
    var description: String { "broker runtime does not support transactional output delivery" }
}
