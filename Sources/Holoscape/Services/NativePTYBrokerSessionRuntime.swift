import Darwin
import Foundation

/// In-process native PTY runtime for the first broker-backed local sessions.
///
/// This is still not the final out-of-process survival broker. It deliberately
/// owns a real PTY/process pair behind `BrokerSessionRuntime`, which lets the
/// coordinator facade exercise launch, input/output, resize, and termination
/// semantics before the process host is moved outside the UI app.
final class NativePTYBrokerSessionRuntime: BrokerSessionRuntime, BrokerSessionAgentStatusOwnerTokenAcknowledgingRuntime, ScrollbackReplayReportingRuntime, BrokerOutputAvailabilityMonitoringRuntime, @unchecked Sendable {
    enum RuntimeError: Error, Equatable {
        case duplicateSession(BrokerSessionID)
        case missingSession(BrokerSessionID)
        case openPTYFailed(errno: Int32)
        case launchFailed(String)
        case invalidGridSize(TerminalGridSize)
        case resizeFailed(errno: Int32)
        case exitCodeMismatch(expected: Int32, observed: Int32)
        case terminationFailed(BrokerSessionID, reason: String)
        case unsupportedEnvironmentProfile(BrokerEnvironmentProfile, reason: String)
    }

    private final class Session: @unchecked Sendable {
        let id: BrokerSessionID
        let process: Process
        let masterHandle: FileHandle
        let scrollbackStore: DiskBackedScrollbackStore?
        private var processGroupID: pid_t?
        private var processGroupCleanupFailureReason: String?
        let lock = NSLock()
        private let terminationLock = NSLock()
        var output = Data()
        var scrollback = Data()
        var terminationStatus: Int32?
        var outputAvailabilityHandler: (@Sendable (BrokerSessionID) -> Void)?
        private let maxScrollbackBytes = ScrollbackPersistencePolicy.maxRetainedBytesPerSession

        init(id: BrokerSessionID, process: Process, masterHandle: FileHandle, scrollbackStore: DiskBackedScrollbackStore?) {
            self.id = id
            self.process = process
            self.masterHandle = masterHandle
            self.scrollbackStore = scrollbackStore
        }

        func appendOutput(_ data: Data) {
            let handler: (@Sendable (BrokerSessionID) -> Void)?
            lock.lock()
            output.append(data)
            scrollback.append(data)
            if scrollback.count > maxScrollbackBytes {
                scrollback.removeFirst(scrollback.count - maxScrollbackBytes)
            }
            handler = outputAvailabilityHandler
            lock.unlock()
            handler?(id)
            do {
                try scrollbackStore?.append(data, for: id)
            } catch {
                NSLog("Broker scrollback persistence failed for \(id.rawValue): \(error)")
            }
        }

        func readOutput() -> Data {
            lock.lock()
            let snapshot = output
            output.removeAll(keepingCapacity: true)
            lock.unlock()
            return snapshot
        }

        func readScrollbackTail(maxBytes: Int) -> Data {
            lock.lock()
            defer { lock.unlock() }
            guard maxBytes > 0 else { return Data() }
            guard scrollback.count > maxBytes else { return scrollback }
            return Data(scrollback.suffix(maxBytes))
        }

        func writeInput(_ data: Data) throws {
            lock.lock()
            defer { lock.unlock() }
            try masterHandle.write(contentsOf: data)
        }

        func markTerminated(_ status: Int32) {
            lock.lock()
            terminationStatus = status
            lock.unlock()
        }

        func handleProcessTermination(
            _ status: Int32,
            signalProcessGroup: @Sendable (pid_t, Int32) -> Int32
        ) {
            terminationLock.lock()
            defer { terminationLock.unlock() }

            lock.lock()
            guard let processGroupID else {
                terminationStatus = status
                lock.unlock()
                return
            }
            lock.unlock()

            let signalError = signalProcessGroup(processGroupID, SIGKILL)
            lock.lock()
            terminationStatus = status
            if signalError == 0 || signalError == ESRCH {
                if self.processGroupID == processGroupID {
                    self.processGroupID = nil
                }
                processGroupCleanupFailureReason = nil
            } else {
                // Once the leader has exited, a bare numeric PGID cannot be
                // retried safely: the kernel may later reuse it for an unrelated
                // process group. Preserve the loud failure, but retire ownership.
                if self.processGroupID == processGroupID {
                    self.processGroupID = nil
                }
                processGroupCleanupFailureReason =
                    "automatic descendant cleanup failed: \(String(cString: strerror(signalError)))"
            }
            lock.unlock()
        }

        func observedTerminationStatus() -> Int32? {
            lock.lock()
            let status = terminationStatus
            lock.unlock()
            return status
        }

        func setOutputAvailabilityHandler(_ handler: (@Sendable (BrokerSessionID) -> Void)?) {
            lock.lock()
            outputAvailabilityHandler = handler
            lock.unlock()
        }

        func setProcessGroupID(_ id: pid_t) -> Int32? {
            lock.lock()
            processGroupID = id
            let status = terminationStatus
            lock.unlock()
            return status
        }

        func observedProcessGroupID() -> pid_t? {
            lock.lock()
            let id = processGroupID
            lock.unlock()
            return id
        }

        func observedProcessGroupCleanupFailureReason() -> String? {
            lock.lock()
            let reason = processGroupCleanupFailureReason
            lock.unlock()
            return reason
        }

        func retireProcessGroup(_ id: pid_t, failureReason: String? = nil) {
            lock.lock()
            if processGroupID == id {
                processGroupID = nil
                processGroupCleanupFailureReason = failureReason
            }
            lock.unlock()
        }

        func withTerminationLock<T>(_ body: () throws -> T) rethrows -> T {
            terminationLock.lock()
            defer { terminationLock.unlock() }
            return try body()
        }
    }

    private let lock = NSLock()
    private var sessions: [BrokerSessionID: Session] = [:]
    private let scrollbackStore: DiskBackedScrollbackStore?
    private let processEnvironment: [String: String]
    private let processGroupSignal: @Sendable (pid_t, Int32) -> Int32
    private static let terminationGracePeriodMilliseconds = 500

    init(
        scrollbackDirectory: URL? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        processGroupSignal: @escaping @Sendable (pid_t, Int32) -> Int32 = { processGroupID, signal in
            Darwin.kill(-processGroupID, signal) == 0 ? 0 : errno
        }
    ) {
        if let scrollbackDirectory {
            self.scrollbackStore = DiskBackedScrollbackStore(directory: scrollbackDirectory)
        } else {
            self.scrollbackStore = nil
        }
        self.processEnvironment = processEnvironment
        self.processGroupSignal = processGroupSignal
    }

    func listSessions() throws -> [BrokerSessionID] {
        lock.lock()
        let ids = sessions.keys.sorted { $0.rawValue < $1.rawValue }
        lock.unlock()
        return ids
    }

    func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {
        lock.lock()
        defer { lock.unlock() }

        if sessions[id] != nil {
            throw RuntimeError.duplicateSession(id)
        }

        try validatePTYGridSize(request.initialSize)
        var resolvedEnvironment = try environment(for: request.environmentProfile)
        if request.environmentProfile == .agentOAuth || request.environmentProfile == .agentAPI,
           let ownerToken = request.agentStatusOwnerToken,
           !ownerToken.isEmpty {
            resolvedEnvironment["HOLOSCAPE_AGENT_STATUS_OWNER_TOKEN"] = ownerToken
        }

        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var size = winsize(
            ws_row: UInt16(request.initialSize.rows),
            ws_col: UInt16(request.initialSize.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        guard openpty(&masterFD, &slaveFD, nil, nil, &size) == 0 else {
            throw RuntimeError.openPTYFailed(errno: errno)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.command)
        process.arguments = request.arguments
        if let workingDirectory = request.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        process.environment = resolvedEnvironment

        let slaveRead = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        let slaveWrite = FileHandle(fileDescriptor: dup(slaveFD), closeOnDealloc: true)
        let slaveError = FileHandle(fileDescriptor: dup(slaveFD), closeOnDealloc: true)
        process.standardInput = slaveRead
        process.standardOutput = slaveWrite
        process.standardError = slaveError

        let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let session = Session(id: id, process: process, masterHandle: masterHandle, scrollbackStore: scrollbackStore)
        let processGroupSignal = self.processGroupSignal
        process.terminationHandler = { [weak session] process in
            session?.handleProcessTermination(
                process.terminationStatus,
                signalProcessGroup: processGroupSignal
            )
        }
        masterHandle.readabilityHandler = { [weak session] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            session?.appendOutput(data)
        }

        do {
            try process.run()
        } catch {
            masterHandle.readabilityHandler = nil
            masterHandle.closeFile()
            slaveRead.closeFile()
            slaveWrite.closeFile()
            slaveError.closeFile()
            throw RuntimeError.launchFailed(error.localizedDescription)
        }

        let expectedProcessGroupID = process.processIdentifier
        let observedProcessGroupID = getpgid(process.processIdentifier)
        if process.isRunning, observedProcessGroupID != expectedProcessGroupID {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            masterHandle.readabilityHandler = nil
            masterHandle.closeFile()
            slaveRead.closeFile()
            slaveWrite.closeFile()
            slaveError.closeFile()
            throw RuntimeError.launchFailed("PTY child did not start in an isolated process group")
        }
        // Foundation launches each Process as its own process-group leader on
        // Darwin. The process group is this runtime's ownership boundary; a
        // command that deliberately moves itself to another group/session has
        // detached from broker-managed terminal lifetime.
        let alreadyTerminatedStatus = session.setProcessGroupID(expectedProcessGroupID)
        if let alreadyTerminatedStatus {
            session.handleProcessTermination(
                alreadyTerminatedStatus,
                signalProcessGroup: processGroupSignal
            )
        } else if !process.isRunning {
            session.handleProcessTermination(
                process.terminationStatus,
                signalProcessGroup: processGroupSignal
            )
        }

        slaveRead.closeFile()
        slaveWrite.closeFile()
        slaveError.closeFile()
        sessions[id] = session
    }

    func createSessionAcknowledgingAgentStatusOwnerToken(
        id: BrokerSessionID,
        request: BrokerSessionLaunchRequest
    ) throws -> Bool {
        try createSession(id: id, request: request)
        let profileAcceptsOwnerToken = request.environmentProfile == .agentOAuth
            || request.environmentProfile == .agentAPI
        return profileAcceptsOwnerToken && request.agentStatusOwnerToken?.isEmpty == false
    }

    func detachSession(id: BrokerSessionID) throws {
        _ = try session(for: id)
    }

    func attachSession(id: BrokerSessionID, channelID: UUID) throws {
        _ = try session(for: id)
    }

    func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {
        let session = try session(for: id)
        try terminateBoundedly(session)
        let observedExitCode = session.process.terminationStatus
        session.markTerminated(observedExitCode)
        if let exitCode, observedExitCode != exitCode {
            throw RuntimeError.exitCodeMismatch(expected: exitCode, observed: observedExitCode)
        }
    }

    func markSessionErrored(id: BrokerSessionID) throws {
        let session = try session(for: id)
        try close(session)
        _ = try removeSession(id)
    }

    func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {
        try session(for: id).writeInput(Data(bytes))
    }

    func readAvailableOutput(id: BrokerSessionID) throws -> Data {
        try session(for: id).readOutput()
    }

    func setOutputAvailabilityHandler(
        id: BrokerSessionID,
        handler: (@Sendable (BrokerSessionID) -> Void)?
    ) throws {
        try session(for: id).setOutputAvailabilityHandler(handler)
    }

    func isOutputMonitoring(id: BrokerSessionID) throws -> Bool {
        try session(for: id).masterHandle.readabilityHandler != nil
    }

    func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data {
        try readScrollbackReplay(id: id, maxBytes: maxBytes).data
    }

    func readScrollbackReplay(id: BrokerSessionID, maxBytes: Int) throws -> ScrollbackReplay {
        if let session = existingSession(for: id) {
            return ScrollbackReplay(
                data: session.readScrollbackTail(maxBytes: maxBytes),
                source: .liveBrokerMemory,
                maxBytes: maxBytes
            )
        }
        if let scrollbackStore {
            return ScrollbackReplay(
                data: try scrollbackStore.readTail(for: id, maxBytes: maxBytes),
                source: .persistedDiskTail,
                maxBytes: maxBytes
            )
        }
        throw RuntimeError.missingSession(id)
    }

    func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {
        let session = try session(for: id)
        try validatePTYGridSize(size)
        var windowSize = winsize(
            ws_row: UInt16(size.rows),
            ws_col: UInt16(size.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard ioctl(session.masterHandle.fileDescriptor, TIOCSWINSZ, &windowSize) == 0 else {
            throw RuntimeError.resizeFailed(errno: errno)
        }
    }

    func isRunning(id: BrokerSessionID) throws -> Bool {
        let session = try session(for: id)
        try throwProcessGroupCleanupErrorIfPresent(for: session)
        return session.process.isRunning
    }

    func terminationStatus(id: BrokerSessionID) throws -> Int32? {
        let session = try session(for: id)
        try throwProcessGroupCleanupErrorIfPresent(for: session)
        if let status = session.observedTerminationStatus() {
            return status
        }
        return session.process.isRunning ? nil : session.process.terminationStatus
    }

    private func close(_ session: Session) throws {
        try terminateBoundedly(session)
        session.masterHandle.readabilityHandler = nil
        session.masterHandle.closeFile()
    }

    private func terminateBoundedly(_ session: Session) throws {
        try session.withTerminationLock {
            try throwProcessGroupCleanupErrorIfPresent(for: session)
            guard let processGroupID = session.observedProcessGroupID() else {
                return
            }

            try signalProcessGroup(processGroupID, signal: SIGTERM, session: session)
            if waitForTermination(of: session.process, processGroupID: processGroupID) {
                session.retireProcessGroup(processGroupID)
                return
            }

            try signalProcessGroup(processGroupID, signal: SIGKILL, session: session)
            guard waitForTermination(of: session.process, processGroupID: processGroupID) else {
                let reason = "process group remained running after SIGTERM and SIGKILL"
                session.retireProcessGroup(processGroupID, failureReason: reason)
                throw RuntimeError.terminationFailed(session.id, reason: reason)
            }
            session.retireProcessGroup(processGroupID)
        }
    }

    private func throwProcessGroupCleanupErrorIfPresent(for session: Session) throws {
        guard let reason = session.observedProcessGroupCleanupFailureReason() else { return }
        throw RuntimeError.terminationFailed(session.id, reason: reason)
    }

    private func signalProcessGroup(
        _ processGroupID: pid_t,
        signal: Int32,
        session: Session
    ) throws {
        let signalError = processGroupSignal(processGroupID, signal)
        if signalError != 0, signalError != ESRCH {
            let reason = "signal \(signal) failed: \(String(cString: strerror(signalError)))"
            session.retireProcessGroup(processGroupID, failureReason: reason)
            throw RuntimeError.terminationFailed(session.id, reason: reason)
        }
    }

    private func waitForTermination(of process: Process, processGroupID: pid_t) -> Bool {
        let deadline = DispatchTime.now() + .milliseconds(Self.terminationGracePeriodMilliseconds)
        while (process.isRunning || processGroupExists(processGroupID)), DispatchTime.now() < deadline {
            usleep(10_000)
        }
        return !process.isRunning && !processGroupExists(processGroupID)
    }

    private func processGroupExists(_ processGroupID: pid_t) -> Bool {
        if Darwin.kill(-processGroupID, 0) == 0 { return true }
        return errno != ESRCH
    }

    private func session(for id: BrokerSessionID) throws -> Session {
        let session = existingSession(for: id)
        guard let session else {
            throw RuntimeError.missingSession(id)
        }
        return session
    }

    private func existingSession(for id: BrokerSessionID) -> Session? {
        lock.lock()
        let session = sessions[id]
        lock.unlock()
        return session
    }

    private func removeSession(_ id: BrokerSessionID) throws -> Session {
        lock.lock()
        let session = sessions.removeValue(forKey: id)
        lock.unlock()
        guard let session else {
            throw RuntimeError.missingSession(id)
        }
        return session
    }

    private func validatePTYGridSize(_ size: TerminalGridSize) throws {
        guard (1...Int(UInt16.max)).contains(size.columns),
              (1...Int(UInt16.max)).contains(size.rows) else {
            throw RuntimeError.invalidGridSize(size)
        }
    }

    private func environment(for profile: BrokerEnvironmentProfile) throws -> [String: String] {
        switch profile {
        case .shell:
            var environment = processEnvironment
            environment.removeValue(forKey: "HOLOSCAPE_AGENT_STATUS_OWNER_TOKEN")
            environment["TERM"] = "xterm-256color"
            if environment["LANG"]?.range(of: "utf", options: [.caseInsensitive]) == nil {
                environment["LANG"] = "en_US.UTF-8"
            }
            // Keep zsh's Apple Terminal-compatible OSC 7 directory updates working
            // while shell sessions are broker-owned instead of SwiftTerm-owned.
            environment["TERM_PROGRAM"] = "Apple_Terminal"
            return environment
        case .agentOAuth:
            // Match AgentChannelController's clean OAuth environment. Inheriting
            // the UI process environment here could silently leak API keys into
            // subscription-billed agent sessions.
            return AuthEnvironmentBuilder.buildEnvironment(
                for: .oauth,
                workingDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
        case .agentAPI:
            // The registry intentionally stores only a profile name, not raw
            // secrets. Until the broker has a Keychain-backed env recipe, API-key
            // sessions must fail loudly instead of launching without auth or
            // inheriting secrets from the UI process.
            throw RuntimeError.unsupportedEnvironmentProfile(
                profile,
                reason: "agent API broker sessions require a Keychain-backed environment recipe"
            )
        case .ssh:
            let allowedKeys: Set<String> = ["PATH", "HOME", "SHELL", "TERM", "LANG", "SSH_AUTH_SOCK"]
            return ProcessInfo.processInfo.environment.filter { allowedKeys.contains($0.key) }
        }
    }
}
