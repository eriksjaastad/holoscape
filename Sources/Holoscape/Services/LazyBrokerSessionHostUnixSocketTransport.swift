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
        case brokerOwnershipIndeterminate(String)
        case launchCleanupFailed(String)
    }

    final class LaunchedChild: @unchecked Sendable {
        let pid: pid_t
        private var reaped = false
        var isReaped: Bool { reaped }

        init(pid: pid_t) {
            self.pid = pid
        }

        func terminateAndReap(graceMilliseconds: Int) throws {
            guard try isRunning() else { return }
            try sendSignal(SIGTERM)
            if try waitForExit(timeoutMilliseconds: graceMilliseconds) { return }

            guard try isRunning() else { return }
            try sendSignal(SIGKILL)
            guard try waitForExit(timeoutMilliseconds: graceMilliseconds) else {
                throw POSIXError(.ETIMEDOUT)
            }
        }

        func reapAfterOwnershipTransfer() {
            DispatchQueue.global(qos: .utility).async { [self] in
                var status: Int32 = 0
                while !reaped {
                    let result = waitpid(pid, &status, 0)
                    if result == pid {
                        reaped = true
                        return
                    }
                    if result == -1, errno == EINTR { continue }
                    if result == -1, errno == ECHILD {
                        NSLog("Broker helper reaper lost child authority for PID %d", pid)
                        reaped = true
                        return
                    }
                    if result == -1 {
                        NSLog("Broker helper reaper failed for PID %d: %s", pid, strerror(errno))
                        return
                    }
                }
            }
        }

        private func sendSignal(_ signal: Int32) throws {
            guard try isRunning() else { return }
            if Darwin.kill(pid, signal) == 0 { return }

            let signalError = errno
            if signalError == ESRCH, try !isRunning() { return }
            throw POSIXError(POSIXErrorCode(rawValue: signalError) ?? .EIO)
        }

        private func waitForExit(timeoutMilliseconds: Int) throws -> Bool {
            let deadline = DispatchTime.now().uptimeNanoseconds
                + UInt64(max(1, timeoutMilliseconds)) * 1_000_000
            while DispatchTime.now().uptimeNanoseconds < deadline {
                if try !isRunning() { return true }
                usleep(10_000)
            }
            return try !isRunning()
        }

        private func isRunning() throws -> Bool {
            guard !reaped else { return false }
            var status: Int32 = 0
            while true {
                let result = waitpid(pid, &status, WNOHANG)
                if result == 0 { return true }
                if result == pid {
                    reaped = true
                    return false
                }
                if result == -1, errno == EINTR { continue }
                if result == -1, errno == ECHILD {
                    throw POSIXError(.ECHILD)
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static let failedLaunchTerminationGraceMilliseconds = 250

    private let executableURL: URL
    private let socketPath: String
    private let environment: [String: String]?
    private let socketWaitTimeoutMilliseconds: Int
    private let requestTimeoutMilliseconds: Int
    private let launchedChildObserver: ((LaunchedChild) -> Void)?
    private let brokerProcessIDProvider: (String) throws -> pid_t
    private let lock = NSLock()
    private var launchedChild: LaunchedChild?

    init(
        executableURL: URL,
        socketPath: String = LazyBrokerSessionHostUnixSocketTransport.defaultSocketPath(),
        environment: [String: String]? = nil,
        socketWaitTimeoutMilliseconds: Int = 5_000,
        requestTimeoutMilliseconds: Int = 10_000,
        launchedChildObserver: ((LaunchedChild) -> Void)? = nil,
        brokerProcessIDProvider: @escaping (String) throws -> pid_t = {
            try BrokerSessionHostUnixSocketServer.activeBrokerProcessID($0)
        }
    ) {
        self.executableURL = executableURL
        self.socketPath = socketPath
        self.environment = environment
        self.socketWaitTimeoutMilliseconds = max(1, socketWaitTimeoutMilliseconds)
        self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
        self.launchedChildObserver = launchedChildObserver
        self.brokerProcessIDProvider = brokerProcessIDProvider
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

        if let launchedChild {
            try waitForLaunchedChild(launchedChild)
            return
        }

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

        let child: LaunchedChild
        do {
            child = try Self.spawnBroker(
                executableURL: executableURL,
                socketPath: socketPath,
                environment: environment
            )
        } catch {
            throw LaunchError.launchFailed(error.localizedDescription)
        }

        launchedChild = child
        launchedChildObserver?(child)
        try waitForLaunchedChild(child)
    }

    private func waitForLaunchedChild(_ child: LaunchedChild) throws {
        do {
            try waitForSocket()
        } catch let readinessError {
            try retireFailedLaunch(child, readinessError: readinessError)
            throw readinessError
        }

        let activeBrokerPID: pid_t
        do {
            activeBrokerPID = try brokerProcessIDProvider(socketPath)
        } catch {
            // Readiness alone cannot prove whether this child or a concurrent
            // broker owns the socket. Retain child authority for a later retry;
            // never signal a process while ownership is indeterminate.
            throw LaunchError.brokerOwnershipIndeterminate(
                "Broker helper PID \(child.pid) reached socket \(socketPath), but lock ownership could not be verified: \(error.localizedDescription)"
            )
        }

        guard activeBrokerPID == child.pid else {
            // Another broker won readiness. Retire only our still-owned child,
            // then let the caller retry against the authoritative socket.
            do {
                try child.terminateAndReap(
                    graceMilliseconds: Self.failedLaunchTerminationGraceMilliseconds
                )
                launchedChild = nil
                return
            } catch let cleanupError {
                throw LaunchError.launchCleanupFailed(
                    "Broker helper PID \(child.pid) did not own reachable socket \(socketPath); cleanup failed with \(cleanupError.localizedDescription)"
                )
            }
        }

        // Matching socket and lock identity transfers termination authority to
        // the session-survival broker. A non-killing reaper remains responsible
        // for this direct child when the broker eventually exits.
        launchedChild = nil
        child.reapAfterOwnershipTransfer()
    }

    private func retireFailedLaunch(_ child: LaunchedChild, readinessError: Error) throws {
        do {
            try child.terminateAndReap(
                graceMilliseconds: Self.failedLaunchTerminationGraceMilliseconds
            )
            launchedChild = nil
        } catch let cleanupError {
            throw LaunchError.launchCleanupFailed(
                "Broker helper PID \(child.pid) readiness failed with \(readinessError); cleanup failed with \(cleanupError.localizedDescription)"
            )
        }
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

    private static func spawnBroker(
        executableURL: URL,
        socketPath: String,
        environment: [String: String]?
    ) throws -> LaunchedChild {
        let executablePath = executableURL.path
        let arguments = [executablePath, BrokerSessionHostCommand.socketModeFlag, socketPath]
        let argumentPointers = try cStringPointers(arguments)
        defer { argumentPointers.forEach { free($0) } }
        var argv: [UnsafeMutablePointer<CChar>?] = argumentPointers.map { Optional($0) }
        argv.append(nil)

        let environmentPointers: [UnsafeMutablePointer<CChar>]
        if let environment {
            let entries = try environment.sorted(by: { $0.key < $1.key }).map { key, value in
                guard !key.isEmpty,
                      !key.contains("="),
                      !key.utf8.contains(0),
                      !value.utf8.contains(0) else {
                    throw POSIXError(.EINVAL)
                }
                return "\(key)=\(value)"
            }
            environmentPointers = try cStringPointers(entries)
        } else {
            environmentPointers = []
        }
        defer { environmentPointers.forEach { free($0) } }
        var envp: [UnsafeMutablePointer<CChar>?] = environmentPointers.map { Optional($0) }
        envp.append(nil)

        var fileActions: posix_spawn_file_actions_t?
        let actionsResult = posix_spawn_file_actions_init(&fileActions)
        guard actionsResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: actionsResult) ?? .EIO)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        for (descriptor, flags) in [
            (STDIN_FILENO, O_RDONLY),
            (STDOUT_FILENO, O_WRONLY),
            (STDERR_FILENO, O_WRONLY),
        ] {
            let result = posix_spawn_file_actions_addopen(
                &fileActions,
                descriptor,
                "/dev/null",
                flags,
                0
            )
            guard result == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
            }
        }

        var pid: pid_t = 0
        let spawnResult = executablePath.withCString { executablePointer in
            argv.withUnsafeMutableBufferPointer { argumentBuffer in
                if environment == nil {
                    return posix_spawn(
                        &pid,
                        executablePointer,
                        &fileActions,
                        nil,
                        argumentBuffer.baseAddress!,
                        environ
                    )
                }
                return envp.withUnsafeMutableBufferPointer { environmentBuffer in
                    posix_spawn(
                        &pid,
                        executablePointer,
                        &fileActions,
                        nil,
                        argumentBuffer.baseAddress!,
                        environmentBuffer.baseAddress!
                    )
                }
            }
        }
        guard spawnResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: spawnResult) ?? .EIO)
        }
        return LaunchedChild(pid: pid)
    }

    private static func cStringPointers(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>] {
        var pointers: [UnsafeMutablePointer<CChar>] = []
        pointers.reserveCapacity(strings.count)
        do {
            for string in strings {
                guard !string.utf8.contains(0), let pointer = strdup(string) else {
                    throw POSIXError(.EINVAL)
                }
                pointers.append(pointer)
            }
            return pointers
        } catch {
            pointers.forEach { free($0) }
            throw error
        }
    }

    static func defaultSocketPath(processInfo: ProcessInfo = .processInfo) -> String {
        let uid = getuid()
        let bundleID = Bundle.main.bundleIdentifier ?? "holoscape"
        let safeBundleID = bundleID.replacingOccurrences(of: "/", with: "-")
        return NSTemporaryDirectory() + "\(safeBundleID)-broker-\(uid).sock"
    }
}
