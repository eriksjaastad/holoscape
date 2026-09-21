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
    private let lock = NSLock()
    private var transport: BrokerSessionHostProcessTransport?

    init(
        executableURL: URL,
        arguments: [String] = [BrokerSessionHostCommand.modeFlag],
        environment: [String: String]? = nil,
        responseTimeoutSeconds: Int = 5
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.responseTimeoutSeconds = responseTimeoutSeconds
    }

    deinit {
        close()
    }

    func sendFrame(_ frame: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let activeTransport: BrokerSessionHostProcessTransport
        if let transport {
            activeTransport = transport
        } else {
            do {
                let launched = try BrokerSessionHostProcessTransport(
                    executableURL: executableURL,
                    arguments: arguments,
                    environment: environment,
                    responseTimeoutSeconds: responseTimeoutSeconds
                )
                BrokerHostLaunchDiagnostics.clearLaunchFailure()
                transport = launched
                activeTransport = launched
            } catch {
                BrokerHostLaunchDiagnostics.recordLaunchFailure(
                    executablePath: executableURL.path,
                    message: String(describing: error)
                )
                throw error
            }
        }
        return try activeTransport.sendFrame(frame)
    }

    func close() {
        lock.lock()
        let activeTransport = transport
        transport = nil
        lock.unlock()
        activeTransport?.close()
    }
}
