import Foundation

/// App-side runtime adapter for the broker host JSON-lines protocol.
///
/// The coordinator talks to `BrokerSessionRuntime`; this adapter lets that same
/// contract cross a process boundary without teaching the coordinator about
/// bytes, pipes, or protocol response shapes. A later launch wrapper can provide
/// the real process transport. Tests can provide an in-process host transport,
/// but the adapter itself contains no silent fallback path.
final class BrokerSessionHostClientRuntime: BrokerSessionRuntime, BrokerOutputAvailabilityMonitoringRuntime, @unchecked Sendable {
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
        return BrokerSessionHostClientRuntime { frame in
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
        try expectOK(.create(id: id, request: request))
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
        let response = try response(for: .readAvailableOutput(id: id))
        guard case let .output(data) = response else {
            throw ClientError.unexpectedResponse(expected: "output", actual: response)
        }
        return data
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
        let response = try codec.decodeResponse(responseFrame)
        if case let .failure(failure) = response {
            throw ClientError.hostFailure(code: failure.code, message: failure.message)
        }
        return response
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
                } catch {
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
