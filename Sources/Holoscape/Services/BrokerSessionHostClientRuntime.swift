import Foundation

/// App-side runtime adapter for the broker host JSON-lines protocol.
///
/// The coordinator talks to `BrokerSessionRuntime`; this adapter lets that same
/// contract cross a process boundary without teaching the coordinator about
/// bytes, pipes, or protocol response shapes. A later launch wrapper can provide
/// the real process transport. Tests can provide an in-process host transport,
/// but the adapter itself contains no silent fallback path.
final class BrokerSessionHostClientRuntime: BrokerSessionRuntime, BrokerSessionAgentStatusOwnerTokenAcknowledgingRuntime, ScrollbackReplayReportingRuntime, BrokerOutputAvailabilityMonitoringRuntime, @unchecked Sendable {
    enum ClientError: Error, Equatable {
        case hostFailure(code: String, message: String)
        case unexpectedResponse(expected: String, actual: BrokerSessionHostResponse)
        case transportFailed(String)
    }

    typealias Transport = (Data) throws -> Data

    private let codec: BrokerSessionHostCodec
    private let transport: Transport
    let supportsOutputAvailabilityMonitoring: Bool
    private let startsOutputAvailabilityMonitor: Bool
    private let outputMonitor = BrokerSessionHostClientOutputMonitor()
    private let outputTransactions = BrokerSessionHostClientOutputTransactions()

    init(
        codec: BrokerSessionHostCodec = BrokerSessionHostCodec(),
        supportsOutputAvailabilityMonitoring: Bool = true,
        startsOutputAvailabilityMonitor: Bool = true,
        transport: @escaping Transport
    ) {
        self.codec = codec
        self.supportsOutputAvailabilityMonitoring = supportsOutputAvailabilityMonitoring
        self.startsOutputAvailabilityMonitor = startsOutputAvailabilityMonitor
        self.transport = transport
    }

    convenience init(
        hostExecutableURL: URL,
        arguments: [String] = [BrokerSessionHostCommand.modeFlag],
        environment: [String: String]? = nil,
        responseTimeoutSeconds: Int = 5,
        codec: BrokerSessionHostCodec = BrokerSessionHostCodec()
    ) {
        let lazyTransport = LazyBrokerSessionHostProcessTransport(
            executableURL: hostExecutableURL,
            arguments: arguments,
            environment: environment,
            responseTimeoutSeconds: responseTimeoutSeconds
        )
        self.init(codec: codec) { frame in
            try lazyTransport.sendFrame(frame)
        }
    }

    static func currentExecutableHostRuntime() -> BrokerSessionHostClientRuntime {
        currentExecutableSocketHostRuntime()
    }

    static func currentExecutableSocketHostRuntime(
        socketPath: String = LazyBrokerSessionHostUnixSocketTransport.defaultSocketPath()
    ) -> BrokerSessionHostClientRuntime {
        let lazyTransport = LazyBrokerSessionHostUnixSocketTransport(
            executableURL: currentExecutableURL(),
            socketPath: socketPath
        )
        return BrokerSessionHostClientRuntime(
            supportsOutputAvailabilityMonitoring: false,
            startsOutputAvailabilityMonitor: false
        ) { frame in
            try lazyTransport.sendFrame(frame)
        }
    }

    private static func currentExecutableURL() -> URL {
        if let executableURL = Bundle.main.executableURL {
            return executableURL
        }
        return URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
    }

    func listSessions() throws -> [BrokerSessionID] {
        let response = try response(for: .listSessions)
        guard case let .sessionIDs(ids) = response else {
            throw ClientError.unexpectedResponse(expected: "sessionIDs", actual: response)
        }
        return ids
    }

    func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {
        let response = try response(for: .create(id: id, request: request))
        guard response == .ok || response == .created(agentStatusOwnerTokenApplied: true) else {
            throw ClientError.unexpectedResponse(expected: "ok or created", actual: response)
        }
    }

    func createSessionAcknowledgingAgentStatusOwnerToken(
        id: BrokerSessionID,
        request: BrokerSessionLaunchRequest
    ) throws -> Bool {
        let response = try response(for: .create(id: id, request: request))
        switch response {
        case let .created(agentStatusOwnerTokenApplied):
            return agentStatusOwnerTokenApplied
        case .ok:
            // Legacy broker hosts ignore the additive request field and return
            // their pre-capability response. The child therefore has no token.
            return false
        default:
            throw ClientError.unexpectedResponse(expected: "ok or created", actual: response)
        }
    }

    func detachSession(id: BrokerSessionID) throws {
        try expectOK(.detach(id: id))
    }

    func attachSession(id: BrokerSessionID, channelID: UUID) throws {
        try expectOK(.attach(id: id, channelID: channelID))
    }

    func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {
        try expectOK(.terminate(id: id, exitCode: exitCode))
    }

    func markSessionErrored(id: BrokerSessionID) throws {
        try expectOK(.markErrored(id: id))
    }

    func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {
        try expectOK(.sendInput(id: id, bytes: Data(bytes)))
    }

    func readAvailableOutput(id: BrokerSessionID) throws -> Data {
        try outputTransactions.withSession(id) {
            try flushPendingOutputAcknowledgment(id: id)
            let response = try response(for: .readAvailableOutput(id: id))
            guard case let .outputSnapshot(snapshot) = response else {
                throw ClientError.unexpectedResponse(expected: "outputSnapshot", actual: response)
            }
            acknowledgeAfterDelivery(id: id, generation: snapshot.generation)
            return snapshot.data
        }
    }

    func setOutputAvailabilityHandler(
        id: BrokerSessionID,
        handler: (@Sendable (BrokerSessionID) -> Void)?
    ) throws {
        guard supportsOutputAvailabilityMonitoring, startsOutputAvailabilityMonitor else { return }
        if let handler {
            outputMonitor.start(
                id: id,
                wait: { [weak self] sessionID in
                    guard let self else { return false }
                    return try self.waitForOutputAvailability(id: sessionID, timeoutMilliseconds: 5_000)
                },
                handler: handler
            )
        } else {
            outputMonitor.stop(id: id)
        }
    }

    func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data {
        let response = try response(for: .readScrollbackTail(id: id, maxBytes: maxBytes))
        guard case let .output(data) = response else {
            throw ClientError.unexpectedResponse(expected: "output", actual: response)
        }
        return data
    }

    func readScrollbackReplay(id: BrokerSessionID, maxBytes: Int) throws -> ScrollbackReplay {
        try outputTransactions.withSession(id) {
            try flushPendingOutputAcknowledgment(id: id)
            let response = try response(for: .readScrollbackReplay(id: id, maxBytes: maxBytes))
            guard case let .scrollbackReplaySnapshot(snapshot) = response else {
                throw ClientError.unexpectedResponse(expected: "scrollbackReplaySnapshot", actual: response)
            }
            acknowledgeAfterDelivery(id: id, generation: snapshot.generation)
            return snapshot.replay
        }
    }

    private func acknowledgeAfterDelivery(id: BrokerSessionID, generation: UInt64?) {
        guard let generation else { return }
        do {
            try expectOK(.acknowledgeOutput(id: id, throughGeneration: generation))
            outputTransactions.clearPending(id: id, through: generation)
        } catch {
            // The bytes are already safely present in this process. Preserve the
            // idempotent acknowledgement for the next read instead of turning an
            // ambiguous ack response into output loss or duplicate delivery.
            outputTransactions.setPending(id: id, generation: generation)
            NSLog("Broker output acknowledgement deferred for \(id.rawValue): \(error)")
        }
    }

    private func flushPendingOutputAcknowledgment(id: BrokerSessionID) throws {
        guard let generation = outputTransactions.pendingGeneration(id: id) else { return }
        try expectOK(.acknowledgeOutput(id: id, throughGeneration: generation))
        outputTransactions.clearPending(id: id, through: generation)
    }

    func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {
        try expectOK(.resize(id: id, size: size))
    }

    func isRunning(id: BrokerSessionID) throws -> Bool {
        let response = try response(for: .isRunning(id: id))
        guard case let .running(isRunning) = response else {
            throw ClientError.unexpectedResponse(expected: "running", actual: response)
        }
        return isRunning
    }

    func terminationStatus(id: BrokerSessionID) throws -> Int32? {
        let response = try response(for: .terminationStatus(id: id))
        guard case let .terminationStatus(status) = response else {
            throw ClientError.unexpectedResponse(expected: "terminationStatus", actual: response)
        }
        return status
    }

    private func expectOK(_ request: BrokerSessionHostRequest) throws {
        let response = try response(for: request)
        guard response == .ok else {
            throw ClientError.unexpectedResponse(expected: "ok", actual: response)
        }
    }

    private func waitForOutputAvailability(id: BrokerSessionID, timeoutMilliseconds: Int) throws -> Bool {
        let response = try response(for: .waitForOutputAvailability(id: id, timeoutMilliseconds: timeoutMilliseconds))
        guard case let .outputAvailable(isAvailable) = response else {
            throw ClientError.unexpectedResponse(expected: "outputAvailable", actual: response)
        }
        return isAvailable
    }

    private func response(for request: BrokerSessionHostRequest) throws -> BrokerSessionHostResponse {
        let requestFrame = try codec.encodeRequest(request)
        let responseFrame: Data
        do {
            responseFrame = try transport(requestFrame)
        } catch let error as ClientError {
            throw error
        } catch {
            throw ClientError.transportFailed(String(describing: error))
        }
        let response: BrokerSessionHostResponse
        do {
            response = try codec.decodeResponse(responseFrame)
        } catch {
            // A malformed or partial response does not prove a mutating request
            // failed before the broker applied it. Preserve that uncertainty as
            // transport failure so callers retain the request's exact identity.
            throw ClientError.transportFailed("responseDecodeFailed(\(error))")
        }
        if case let .failure(failure) = response {
            throw ClientError.hostFailure(code: failure.code, message: failure.message)
        }
        return response
    }
}

extension BrokerSessionHostClientRuntime.ClientError {
    var ambiguousCreateFailureReason: String? {
        switch self {
        case .transportFailed(let reason):
            return reason
        case .unexpectedResponse(let expected, let actual):
            return "unexpected response; expected \(expected), got \(actual)"
        case .hostFailure:
            return nil
        }
    }
}

private final class BrokerSessionHostClientOutputTransactions: @unchecked Sendable {
    private let stateLock = NSLock()
    private var sessionLocks: [BrokerSessionID: NSRecursiveLock] = [:]
    private var pendingAcknowledgments: [BrokerSessionID: UInt64] = [:]

    func withSession<T>(_ id: BrokerSessionID, operation: () throws -> T) rethrows -> T {
        stateLock.lock()
        let lock = sessionLocks[id] ?? NSRecursiveLock()
        sessionLocks[id] = lock
        stateLock.unlock()
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    func pendingGeneration(id: BrokerSessionID) -> UInt64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pendingAcknowledgments[id]
    }

    func setPending(id: BrokerSessionID, generation: UInt64) {
        stateLock.lock()
        pendingAcknowledgments[id] = max(pendingAcknowledgments[id] ?? 0, generation)
        stateLock.unlock()
    }

    func clearPending(id: BrokerSessionID, through generation: UInt64) {
        stateLock.lock()
        if let pending = pendingAcknowledgments[id], pending <= generation {
            pendingAcknowledgments.removeValue(forKey: id)
        }
        stateLock.unlock()
    }
}

private final class BrokerSessionHostClientOutputMonitor: @unchecked Sendable {
    private struct Monitor {
        let generation: UUID
        let queue: DispatchQueue
    }

    private let lock = NSLock()
    private var monitors: [BrokerSessionID: Monitor] = [:]

    func start(
        id: BrokerSessionID,
        wait: @escaping @Sendable (BrokerSessionID) throws -> Bool,
        handler: @escaping @Sendable (BrokerSessionID) -> Void
    ) {
        stop(id: id)
        let generation = UUID()
        let queue = DispatchQueue(
            label: "holoscape.broker.host-client.output-availability.\(id.rawValue)",
            qos: .userInteractive
        )
        lock.withLock {
            monitors[id] = Monitor(generation: generation, queue: queue)
        }
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            while self?.isActive(id: id, generation: generation) == true {
                do {
                    if try wait(id), self?.isActive(id: id, generation: generation) == true {
                        handler(id)
                    }
                } catch BrokerSessionHostClientRuntime.ClientError.transportFailed {
                    guard self?.isActive(id: id, generation: generation) == true else { return }
                    Thread.sleep(forTimeInterval: 0.25)
                } catch {
                    NSLog("Broker output availability monitor stopped for %@: %@", id.rawValue, String(describing: error))
                    self?.stopIfCurrent(id: id, generation: generation)
                    return
                }
            }
        }
    }

    func stop(id: BrokerSessionID) {
        lock.withLock {
            monitors[id] = nil
        }
    }

    private func isActive(id: BrokerSessionID, generation: UUID) -> Bool {
        lock.withLock { monitors[id]?.generation == generation }
    }

    private func stopIfCurrent(id: BrokerSessionID, generation: UUID) {
        lock.withLock {
            if monitors[id]?.generation == generation {
                monitors[id] = nil
            }
        }
    }

}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
