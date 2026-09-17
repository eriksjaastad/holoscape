import Darwin
import Foundation

/// Lazily ensures a Unix-socket broker host is running, then sends one frame per
/// connection through `BrokerSessionHostUnixSocketTransport`.
///
/// Unlike the stdio helper transport, this launcher intentionally does not kill
/// the broker host from `deinit`: the socket host is the session-survival
/// boundary, so app shutdown must leave the broker process and its PTYs alive.
final class LazyBrokerSessionHostUnixSocketTransport: @unchecked Sendable {
    enum LaunchError: Error, Equatable {
        case launchFailed(String)
        case socketTimedOut(String)
    }

    private let executableURL: URL
    private let socketPath: String
    private let environment: [String: String]?
    private let socketWaitTimeoutMilliseconds: Int
    private let lock = NSLock()
    private var launchedProcess: Process?

    init(
        executableURL: URL,
        socketPath: String = LazyBrokerSessionHostUnixSocketTransport.defaultSocketPath(),
        environment: [String: String]? = nil,
        socketWaitTimeoutMilliseconds: Int = 5_000
    ) {
        self.executableURL = executableURL
        self.socketPath = socketPath
        self.environment = environment
        self.socketWaitTimeoutMilliseconds = socketWaitTimeoutMilliseconds
    }

    func sendFrame(_ frame: Data) throws -> Data {
        try ensureBrokerIsReachable()
        let transport = BrokerSessionHostUnixSocketTransport(socketPath: socketPath)
        return try transport.sendFrame(frame)
    }

    private func ensureBrokerIsReachable() throws {
        lock.lock()
        defer { lock.unlock() }

        if isSocketConnectable() {
            return
        }

        if let launchedProcess, launchedProcess.isRunning {
            try waitForSocket()
            return
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [BrokerSessionHostCommand.socketModeFlag, socketPath]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw LaunchError.launchFailed(error.localizedDescription)
        }

        launchedProcess = process
        try waitForSocket()
    }

    private func waitForSocket() throws {
        let deadline = Date().addingTimeInterval(Double(socketWaitTimeoutMilliseconds) / 1_000.0)
        while Date() < deadline {
            if isSocketConnectable() {
                return
            }
            usleep(10_000)
        }
        throw LaunchError.socketTimedOut(socketPath)
    }

    private func isSocketConnectable() -> Bool {
        do {
            let probeFrame = try BrokerSessionHostCodec().encodeRequest(.listSessions)
            _ = try BrokerSessionHostUnixSocketTransport(socketPath: socketPath).sendFrame(probeFrame)
            return true
        } catch {
            return false
        }
    }

    static func defaultSocketPath(processInfo: ProcessInfo = .processInfo) -> String {
        let uid = getuid()
        let bundleID = Bundle.main.bundleIdentifier ?? "holoscape"
        let safeBundleID = bundleID.replacingOccurrences(of: "/", with: "-")
        return NSTemporaryDirectory() + "\(safeBundleID)-broker-\(uid).sock"
    }
}
