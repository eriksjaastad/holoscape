import Darwin
import Foundation

/// In-process native PTY runtime for the first broker-backed local sessions.
///
/// This is still not the final out-of-process survival broker. It deliberately
/// owns a real PTY/process pair behind `BrokerSessionRuntime`, which lets the
/// coordinator facade exercise launch, input/output, resize, and termination
/// semantics before the process host is moved outside the UI app.
final class NativePTYBrokerSessionRuntime: BrokerSessionRuntime, BrokerSessionAgentStatusOwnerTokenAcknowledgingRuntime, ScrollbackReplayReportingRuntime, BrokerOutputAvailabilityMonitoringRuntime, BrokerTransactionalOutputRuntime, @unchecked Sendable {
    enum RuntimeError: Error, Equatable {
        case duplicateSession(BrokerSessionID)
        case missingSession(BrokerSessionID)
        case openPTYFailed(errno: Int32)
        case launchFailed(String)
        case invalidGridSize(TerminalGridSize)
        case resizeFailed(errno: Int32)
        case exitCodeMismatch(expected: Int32, observed: Int32)
        case terminationFailed(BrokerSessionID, reason: String)
        case scrollbackPersistenceFailed(BrokerSessionID, reason: String)
        case unsupportedEnvironmentProfile(BrokerEnvironmentProfile, reason: String)
    }

    private final class Session: @unchecked Sendable {
        let id: BrokerSessionID
        let process: Process
        let masterHandle: FileHandle
        let scrollbackAppender: (@Sendable (Data, BrokerSessionID) throws -> Void)?
        private var processGroupID: pid_t?
        private var processGroupCleanupFailureReason: String?
        let lock = NSLock()
        private let terminationLock = NSLock()
        var output = Data()
        private var outputStartOffset: UInt64 = 0
        private var outputEndOffset: UInt64 = 0
        private var legacyReplayPresented = false
        var scrollback = Data()
        private var scrollbackPersistenceFailureReason: String?
        private var pendingScrollbackPersistenceWrites = 0
        private var outputMonitoringComplete = false
        var terminationStatus: Int32?
        var outputAvailabilityHandler: (@Sendable (BrokerSessionID) -> Void)?
        private let maxScrollbackBytes = ScrollbackPersistencePolicy.maxRetainedBytesPerSession

        init(
            id: BrokerSessionID,
            process: Process,
            masterHandle: FileHandle,
            scrollbackAppender: (@Sendable (Data, BrokerSessionID) throws -> Void)?
        ) {
            self.id = id
            self.process = process
            self.masterHandle = masterHandle
            self.scrollbackAppender = scrollbackAppender
        }

        func appendOutput(_ data: Data) {
            let shouldPersist: Bool
            lock.lock()
            output.append(data)
            outputEndOffset &+= UInt64(data.count)
            scrollback.append(data)
            if scrollback.count > maxScrollbackBytes {
                scrollback.removeFirst(scrollback.count - maxScrollbackBytes)
            }
            shouldPersist = scrollbackAppender != nil && scrollbackPersistenceFailureReason == nil
            if shouldPersist {
                pendingScrollbackPersistenceWrites += 1
            }
            lock.unlock()
            if shouldPersist, let scrollbackAppender {
                do {
                    try scrollbackAppender(data, id)
                    lock.lock()
                    pendingScrollbackPersistenceWrites -= 1
                    lock.unlock()
                } catch {
                    let reason = String(describing: error)
                    lock.lock()
                    pendingScrollbackPersistenceWrites -= 1
                    if scrollbackPersistenceFailureReason == nil {
                        scrollbackPersistenceFailureReason = reason
                    }
                    lock.unlock()
                    NSLog("Broker scrollback persistence failed for \(id.rawValue): \(reason)")
                }
            }
            // Wake readers only after persistence has either succeeded or its
            // failure has been retained, so the first awakened read cannot race
            // past a durability failure and leave the terminal looking healthy.
            lock.lock()
            let handler = outputAvailabilityHandler
            lock.unlock()
            handler?(id)
        }

        func snapshotOutput() throws -> BrokerOutputSnapshot {
            lock.lock()
            if let reason = scrollbackPersistenceFailureReason {
                lock.unlock()
                throw RuntimeError.scrollbackPersistenceFailed(id, reason: reason)
            }
            guard pendingScrollbackPersistenceWrites == 0 else {
                lock.unlock()
                return BrokerOutputSnapshot(data: Data(), generation: nil)
            }
            let snapshot = BrokerOutputSnapshot(
                data: output,
                generation: output.isEmpty ? nil : outputEndOffset
            )
            lock.unlock()
            return snapshot
        }

        func acknowledgeOutput(through generation: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            acknowledgeOutputLocked(through: generation)
        }

        private func acknowledgeOutputLocked(through generation: UInt64) {
            guard generation > outputStartOffset else { return }
            let boundedGeneration = min(generation, outputEndOffset)
            let acknowledgedCount = boundedGeneration - outputStartOffset
            guard acknowledgedCount <= UInt64(output.count) else { return }
            output.removeFirst(Int(acknowledgedCount))
            outputStartOffset = boundedGeneration
        }

        func readOutput() throws -> Data {
            lock.lock()
            defer { lock.unlock() }
            if let reason = scrollbackPersistenceFailureReason {
                throw RuntimeError.scrollbackPersistenceFailed(id, reason: reason)
            }
            guard pendingScrollbackPersistenceWrites == 0 else { return Data() }
            let snapshot = BrokerOutputSnapshot(
                data: output,
                generation: output.isEmpty ? nil : outputEndOffset
            )
            if let generation = snapshot.generation {
                acknowledgeOutputLocked(through: generation)
            }
            return snapshot.data
        }

        func readScrollbackTail(maxBytes: Int) -> Data {
            lock.lock()
            defer { lock.unlock() }
            guard maxBytes > 0 else { return Data() }
            guard scrollback.count > maxBytes else { return scrollback }
            return Data(scrollback.suffix(maxBytes))
        }

        /// Snapshot retained scrollback and consume the corresponding unread
        /// live-output generation under one lock. Bytes appended after the
        /// snapshot remain unread, so replay followed by the output pump emits
        /// every byte exactly once across detach/reattach.
        func snapshotScrollbackReplay(maxBytes: Int) throws -> BrokerScrollbackReplaySnapshot {
            lock.lock()
            defer { lock.unlock() }
            if let reason = scrollbackPersistenceFailureReason {
                throw RuntimeError.scrollbackPersistenceFailed(id, reason: reason)
            }
            // Replay may consume unread output only when the returned tail can
            // contain that generation in full. Otherwise the live pump owns all
            // unread bytes, preserving order without truncation or duplication.
            guard pendingScrollbackPersistenceWrites == 0,
                  maxBytes > 0,
                  output.count <= maxBytes,
                  output.count <= scrollback.count else {
                return BrokerScrollbackReplaySnapshot(
                    replay: ScrollbackReplay(data: Data(), source: .liveBrokerMemory, maxBytes: maxBytes),
                    generation: nil
                )
            }
            let replay = scrollback.count > maxBytes
                ? Data(scrollback.suffix(maxBytes))
                : scrollback
            return BrokerScrollbackReplaySnapshot(
                replay: ScrollbackReplay(data: replay, source: .liveBrokerMemory, maxBytes: maxBytes),
                generation: output.isEmpty ? nil : outputEndOffset
            )
        }

        func readScrollbackReplay(maxBytes: Int) throws -> Data {
            lock.lock()
            defer { lock.unlock() }
            if let reason = scrollbackPersistenceFailureReason {
                throw RuntimeError.scrollbackPersistenceFailed(id, reason: reason)
            }
            guard pendingScrollbackPersistenceWrites == 0,
                  maxBytes > 0,
                  output.count <= maxBytes,
                  output.count <= scrollback.count else { return Data() }
            guard !output.isEmpty || !legacyReplayPresented else { return Data() }
            let replay = scrollback.count > maxBytes
                ? Data(scrollback.suffix(maxBytes))
                : scrollback
            let generation = output.isEmpty ? nil : outputEndOffset
            if !replay.isEmpty {
                legacyReplayPresented = true
            }
            if let generation {
                acknowledgeOutputLocked(through: generation)
            }
            return replay
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

        func observedTerminationStatus(processFallback: Int32? = nil) throws -> Int32? {
            lock.lock()
            if let reason = scrollbackPersistenceFailureReason {
                lock.unlock()
                throw RuntimeError.scrollbackPersistenceFailed(id, reason: reason)
            }
            guard outputMonitoringComplete, pendingScrollbackPersistenceWrites == 0 else {
                lock.unlock()
                return nil
            }
            let status = terminationStatus ?? processFallback
            lock.unlock()
            return status
        }

        func throwScrollbackPersistenceErrorIfPresent() throws {
            lock.lock()
            let reason = scrollbackPersistenceFailureReason
            lock.unlock()
            if let reason {
                throw RuntimeError.scrollbackPersistenceFailed(id, reason: reason)
            }
        }

        func markOutputMonitoringComplete() {
            lock.lock()
            outputMonitoringComplete = true
            let handler = outputAvailabilityHandler
            lock.unlock()
            handler?(id)
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
    private let scrollbackAppender: (@Sendable (Data, BrokerSessionID) throws -> Void)?
    private let processEnvironment: [String: String]
    private let processGroupSignal: @Sendable (pid_t, Int32) -> Int32
    private static let terminationGracePeriodMilliseconds = 500

    init(
        scrollbackDirectory: URL? = nil,
        scrollbackAppender: (@Sendable (Data, BrokerSessionID) throws -> Void)? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        processGroupSignal: @escaping @Sendable (pid_t, Int32) -> Int32 = { processGroupID, signal in
            Darwin.kill(-processGroupID, signal) == 0 ? 0 : errno
        }
    ) {
        if let scrollbackDirectory {
            let store = DiskBackedScrollbackStore(directory: scrollbackDirectory)
            self.scrollbackStore = store
            self.scrollbackAppender = scrollbackAppender ?? { data, id in
                try store.append(data, for: id)
            }
        } else {
            self.scrollbackStore = nil
            self.scrollbackAppender = scrollbackAppender
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
        let session = Session(
            id: id,
            process: process,
            masterHandle: masterHandle,
            scrollbackAppender: scrollbackAppender
        )
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
                session?.markOutputMonitoringComplete()
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

    func snapshotAvailableOutput(id: BrokerSessionID) throws -> BrokerOutputSnapshot {
        try session(for: id).snapshotOutput()
    }

    func acknowledgeOutput(id: BrokerSessionID, through generation: UInt64) throws {
        try session(for: id).acknowledgeOutput(through: generation)
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
        if let session = existingSession(for: id) {
            return session.readScrollbackTail(maxBytes: maxBytes)
        }
        if let scrollbackStore {
            return try scrollbackStore.readTail(for: id, maxBytes: maxBytes)
        }
        throw RuntimeError.missingSession(id)
    }

    func readScrollbackReplay(id: BrokerSessionID, maxBytes: Int) throws -> ScrollbackReplay {
        if let session = existingSession(for: id) {
            return ScrollbackReplay(
                data: try session.readScrollbackReplay(maxBytes: maxBytes),
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

    func snapshotScrollbackReplay(id: BrokerSessionID, maxBytes: Int) throws -> BrokerScrollbackReplaySnapshot {
        if let session = existingSession(for: id) {
            return try session.snapshotScrollbackReplay(maxBytes: maxBytes)
        }
        if let scrollbackStore {
            return BrokerScrollbackReplaySnapshot(
                replay: ScrollbackReplay(
                    data: try scrollbackStore.readTail(for: id, maxBytes: maxBytes),
                    source: .persistedDiskTail,
                    maxBytes: maxBytes
                ),
                generation: nil
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
        try session.throwScrollbackPersistenceErrorIfPresent()
        return session.process.isRunning
    }

    func terminationStatus(id: BrokerSessionID) throws -> Int32? {
        let session = try session(for: id)
        try throwProcessGroupCleanupErrorIfPresent(for: session)
        let processFallback = session.process.isRunning ? nil : session.process.terminationStatus
        return try session.observedTerminationStatus(processFallback: processFallback)
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
