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
        case launchCleanupFailed(String)
    }

    private static let failedLaunchTerminationGraceMilliseconds = 250

    private let executableURL: URL
    private let socketPath: String
    private let environment: [String: String]?
    private let socketWaitTimeoutMilliseconds: Int
    private let requestTimeoutMilliseconds: Int
    private let launchedProcessObserver: ((Process) -> Void)?
    private let lock = NSLock()
    private var launchedProcess: Process?

    init(
        executableURL: URL,
        socketPath: String = LazyBrokerSessionHostUnixSocketTransport.defaultSocketPath(),
        environment: [String: String]? = nil,
        socketWaitTimeoutMilliseconds: Int = 5_000,
        requestTimeoutMilliseconds: Int = 10_000,
        launchedProcessObserver: ((Process) -> Void)? = nil
    ) {
        self.executableURL = executableURL
        self.socketPath = socketPath
        self.environment = environment
        self.socketWaitTimeoutMilliseconds = max(1, socketWaitTimeoutMilliseconds)
        self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
        self.launchedProcessObserver = launchedProcessObserver
    }

    func sendFrame(_ frame: Data) throws -> Data {
        let transport = BrokerSessionHostUnixSocketTransport(
            socketPath: socketPath,
            requestTimeoutMilliseconds: requestTimeoutMilliseconds
        )
        do {
            return try transport.sendFrame(frame)
        } catch BrokerSessionHostUnixSocketTransport.TransportError.connectFailed {
            try ensureBrokerIsReachableAfterConnectionFailure()
            return try transport.sendFrame(frame)
        }
    }

    private func ensureBrokerIsReachableAfterConnectionFailure() throws {
        lock.lock()
        defer { lock.unlock() }

        switch socketReachability() {
        case .reachable:
            return
        case .indeterminate:
            throw LaunchError.socketTimedOut(socketPath)
        case .unreachable:
            break
        }

        if BrokerSessionHostUnixSocketServer.socketPathHasActiveBrokerLock(socketPath) {
            if !FileManager.default.fileExists(atPath: socketPath) {
                try waitForSocket()
            }
            return
        }

        if let launchedProcess, launchedProcess.isRunning {
            try waitForLaunchedProcess(launchedProcess)
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
        launchedProcessObserver?(process)
        try waitForLaunchedProcess(process)
    }

    private func waitForLaunchedProcess(_ process: Process) throws {
        do {
            try waitForSocket()
            // Once reachable, ownership transfers to the session-survival broker.
            // Dropping our Process handle must not terminate that successful host.
            launchedProcess = nil
        } catch let readinessError {
            do {
                try terminateFailedLaunch(process)
                launchedProcess = nil
            } catch let cleanupError {
                throw LaunchError.launchCleanupFailed(
                    "Broker helper PID \(process.processIdentifier) readiness failed with \(readinessError); cleanup failed with \(cleanupError.localizedDescription)"
                )
            }
            throw readinessError
        }
    }

    private func terminateFailedLaunch(_ process: Process) throws {
        guard process.isRunning else { return }
        guard Darwin.kill(process.processIdentifier, SIGTERM) == 0 || errno == ESRCH else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if waitForProcessExit(process) { return }

        guard Darwin.kill(process.processIdentifier, SIGKILL) == 0 || errno == ESRCH else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard waitForProcessExit(process) else {
            throw POSIXError(.ETIMEDOUT)
        }
    }

    private func waitForProcessExit(_ process: Process) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(Self.failedLaunchTerminationGraceMilliseconds) * 1_000_000
        while process.isRunning, DispatchTime.now().uptimeNanoseconds < deadline {
            usleep(10_000)
        }
        return !process.isRunning
    }

    private func waitForSocket() throws {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(socketWaitTimeoutMilliseconds) * 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if socketReachability() == .reachable {
                return
            }
            usleep(10_000)
        }
        throw LaunchError.socketTimedOut(socketPath)
    }

    private func socketReachability() -> BrokerSessionHostUnixSocketServer.Reachability {
        BrokerSessionHostUnixSocketServer.socketPathBrokerReachability(
            socketPath,
            timeoutMilliseconds: min(250, socketWaitTimeoutMilliseconds)
        )
    }

    static func defaultSocketPath(processInfo: ProcessInfo = .processInfo) -> String {
        let uid = getuid()
        let bundleID = Bundle.main.bundleIdentifier ?? "holoscape"
        let safeBundleID = bundleID.replacingOccurrences(of: "/", with: "-")
        return NSTemporaryDirectory() + "\(safeBundleID)-broker-\(uid).sock"
    }
}
