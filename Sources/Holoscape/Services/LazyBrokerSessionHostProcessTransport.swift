import Foundation

/// Lazily starts the broker host process on the first protocol request.
///
/// Channel creation should not launch helper processes, but the first broker-owned
/// shell operation must cross the explicit `--broker-host` boundary and fail
/// loudly if that helper cannot start. This adapter keeps that boundary lazy
/// without providing an in-process fallback.
final class LazyBrokerSessionHostProcessTransport: @unchecked Sendable {
    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]?
    private let responseTimeoutSeconds: Int
    private let transportFactory: (URL, [String], [String: String]?, Int) throws -> BrokerSessionHostProcessTransport
    private let lock = NSLock()
    private var transport: BrokerSessionHostProcessTransport?
    private var isClosed = false

    init(
        executableURL: URL,
        arguments: [String] = [BrokerSessionHostCommand.modeFlag],
        environment: [String: String]? = nil,
        responseTimeoutSeconds: Int = 5,
        transportFactory: @escaping (URL, [String], [String: String]?, Int) throws -> BrokerSessionHostProcessTransport = { executableURL, arguments, environment, responseTimeoutSeconds in
            try BrokerSessionHostProcessTransport(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment,
                responseTimeoutSeconds: responseTimeoutSeconds
            )
        }
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.responseTimeoutSeconds = responseTimeoutSeconds
        self.transportFactory = transportFactory
    }

    deinit {
        close()
    }

    func sendFrame(_ frame: Data) throws -> Data {
        let activeTransport = try transportForFrame()
        return try activeTransport.sendFrame(frame)
    }

    private func transportForFrame() throws -> BrokerSessionHostProcessTransport {
        lock.lock()
        defer { lock.unlock() }
        if isClosed {
            throw BrokerSessionHostProcessTransport.TransportError.transportClosed
        }
        if let transport {
            return transport
        }
        do {
            let launched = try transportFactory(executableURL, arguments, environment, responseTimeoutSeconds)
            BrokerHostLaunchDiagnostics.clearLaunchFailure()
            transport = launched
            return launched
        } catch {
            BrokerHostLaunchDiagnostics.recordLaunchFailure(
                executablePath: executableURL.path,
                message: String(describing: error)
            )
            throw error
        }
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let activeTransport = transport
        transport = nil
        lock.unlock()
        activeTransport?.close()
    }
}
