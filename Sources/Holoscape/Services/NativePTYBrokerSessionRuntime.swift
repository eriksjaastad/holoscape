import Darwin
import Foundation
import CNativePTY

final class NativePTYChildProcess: @unchecked Sendable {
    struct LaunchFailure: Error {
        let errno: Int32
        let masterDescriptor: Int32
        let process: NativePTYChildProcess?
    }
    struct TerminationObservation: Sendable {
        let status: Int32?
        let waitError: Int32?
        let foregroundProcessGroupID: pid_t?
    }
    typealias Waiter = @Sendable (pid_t, pid_t, Int32) -> TerminationObservation
    typealias Reaper = @Sendable (pid_t) -> TerminationObservation
    typealias TerminationHandler = @Sendable (NativePTYChildProcess) -> Void

    let processIdentifier: pid_t
    let processGroupID: pid_t
    private let masterDescriptor: Int32
    private let lock = NSLock()
    private let lifecycleLock = NSLock()
    private var running = true
    private var cleanupComplete = false
    private var exitObserved = false
    private var retainedForegroundProcessGroupID: pid_t?
    private var ownsMasterDescriptor = false
    private var masterDescriptorClosed = false
    private var status: Int32 = 0
    private var waitError: Int32?
    private var storedTerminationHandler: TerminationHandler?
    private var waitingStarted = false
    private let waiter: Waiter
    private let reaper: Reaper
    private static let exitObservationRetryDelayMicroseconds: useconds_t = 10_000

    var isRunning: Bool {
        lock.withLock { running }
    }

    var terminationObservation: TerminationObservation {
        lock.withLock {
            TerminationObservation(
                status: !cleanupComplete || waitError != nil ? nil : status,
                waitError: waitError,
                foregroundProcessGroupID: retainedForegroundProcessGroupID
            )
        }
    }

    var cleanupIsComplete: Bool { lock.withLock { cleanupComplete } }

    func retainMasterDescriptorUntilCleanupCompletes() {
        lock.withLock { ownsMasterDescriptor = true }
    }

    var terminationHandler: TerminationHandler? {
        get { lock.withLock { storedTerminationHandler } }
        set {
            let shouldNotify = lock.withLock {
                storedTerminationHandler = newValue
                return !running && newValue != nil
            }
            if shouldNotify { newValue?(self) }
        }
    }

    private init(
        processIdentifier: pid_t,
        processGroupID: pid_t,
        masterDescriptor: Int32,
        waiter: @escaping Waiter,
        reaper: @escaping Reaper
    ) {
        self.processIdentifier = processIdentifier
        self.processGroupID = processGroupID
        self.masterDescriptor = masterDescriptor
        self.waiter = waiter
        self.reaper = reaper
    }

    func startWaiting(
        signalProcessGroup: @escaping @Sendable (pid_t, Int32) -> Int32,
        cleanupTimeoutMilliseconds: Int
    ) {
        let shouldStart = lock.withLock {
            guard !waitingStarted else { return false }
            waitingStarted = true
            return true
        }
        guard shouldStart else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let observation: TerminationObservation
            while true {
                let attempt = waiter(processIdentifier, processIdentifier, masterDescriptor)
                let shouldRetry = attempt.waitError == EAGAIN || attempt.waitError == EINTR
                lock.withLock {
                    waitError = attempt.waitError
                    if let foreground = attempt.foregroundProcessGroupID {
                        retainedForegroundProcessGroupID = foreground
                    }
                }
                guard shouldRetry else {
                    observation = attempt
                    break
                }

                // A foreground/session snapshot can race process-group turnover
                // before waitid confirms leader exit. Keep the one waiter as the
                // observation authority, expose the transient error to status
                // callers, and retry with a delay rather than declaring the
                // process stopped or spinning on a reused PID.
                usleep(Self.exitObservationRetryDelayMicroseconds)
            }
            lock.withLock {
                running = false
                if let foreground = observation.foregroundProcessGroupID {
                    retainedForegroundProcessGroupID = foreground
                }
                exitObserved = observation.waitError == nil
                waitError = observation.waitError
            }
            let finalObservation: TerminationObservation
            if observation.waitError == nil {
                finalObservation = finishObservedExitCleanup(
                    signalProcessGroup: signalProcessGroup,
                    cleanupTimeoutMilliseconds: cleanupTimeoutMilliseconds
                )
            } else {
                finalObservation = observation
            }
            let handler = lock.withLock { () -> TerminationHandler? in
                if let observedStatus = finalObservation.status {
                    status = observedStatus
                }
                waitError = finalObservation.waitError
                return storedTerminationHandler
            }
            handler?(self)
        }
    }

    func signalOwnedProcessGroups(
        _ signal: Int32,
        signalProcessGroup: @Sendable (pid_t, Int32) -> Int32
    ) -> Int32 {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        if lock.withLock({ cleanupComplete }) { return 0 }
        return signalLiveSessionProcessGroups(signal, signalProcessGroup: signalProcessGroup)
    }

    func retryObservedExitCleanup(
        signalProcessGroup: @escaping @Sendable (pid_t, Int32) -> Int32,
        cleanupTimeoutMilliseconds: Int
    ) -> TerminationObservation {
        guard lock.withLock({ exitObserved && !cleanupComplete }) else {
            return terminationObservation
        }
        let observation = finishObservedExitCleanup(
            signalProcessGroup: signalProcessGroup,
            cleanupTimeoutMilliseconds: cleanupTimeoutMilliseconds
        )
        lock.withLock {
            if let observedStatus = observation.status { status = observedStatus }
            waitError = observation.waitError
        }
        return observation
    }

    private func finishObservedExitCleanup(
        signalProcessGroup: @escaping @Sendable (pid_t, Int32) -> Int32,
        cleanupTimeoutMilliseconds: Int
    ) -> TerminationObservation {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        if lock.withLock({ cleanupComplete }) { return terminationObservation }

        let foreground = lock.withLock { retainedForegroundProcessGroupID }
        if let barrierError = killLiveSessionProcessGroupsUntilExit(
            signalProcessGroup: signalProcessGroup,
            timeoutMilliseconds: cleanupTimeoutMilliseconds
        ) {
            return TerminationObservation(
                status: nil,
                waitError: barrierError,
                foregroundProcessGroupID: foreground
            )
        }

        let reaped = reaper(processIdentifier)
        guard reaped.waitError == nil else {
            return TerminationObservation(
                status: nil,
                waitError: reaped.waitError,
                foregroundProcessGroupID: foreground
            )
        }
        lock.withLock {
            cleanupComplete = true
            retainedForegroundProcessGroupID = nil
        }
        let shouldCloseMaster = lock.withLock { () -> Bool in
            guard ownsMasterDescriptor, !masterDescriptorClosed else { return false }
            masterDescriptorClosed = true
            return true
        }
        if shouldCloseMaster {
            _ = Darwin.close(masterDescriptor)
        }
        return TerminationObservation(
            status: reaped.status,
            waitError: nil,
            foregroundProcessGroupID: nil
        )
    }

    private func copyLiveSessionProcessGroups() -> (groups: [pid_t], error: Int32?) {
        var pointer: UnsafeMutablePointer<pid_t>?
        var count = 0
        let copyError = holoscape_copy_live_session_process_groups(
            processIdentifier,
            &pointer,
            &count
        )
        defer { holoscape_free_process_group_ids(pointer) }
        guard copyError == 0 else { return ([], copyError) }
        guard let pointer, count > 0 else { return ([], nil) }
        return (Array(UnsafeBufferPointer(start: pointer, count: count)), nil)
    }

    private func signalLiveSessionProcessGroups(
        _ signal: Int32,
        signalProcessGroup: @Sendable (pid_t, Int32) -> Int32
    ) -> Int32 {
        let snapshot = copyLiveSessionProcessGroups()
        if let snapshotError = snapshot.error { return snapshotError }
        return signalValidatedProcessGroups(
            snapshot.groups,
            signal: signal,
            signalProcessGroup: signalProcessGroup
        )
    }

    private func signalValidatedProcessGroups(
        _ processGroupIDs: [pid_t],
        signal: Int32,
        signalProcessGroup: @Sendable (pid_t, Int32) -> Int32
    ) -> Int32 {
        for processGroupID in processGroupIDs {
            // The unreaped session leader keeps the session identifier from being
            // reused. Revalidate each enumerated group immediately before signaling
            // so a disappeared/reused PGID is never trusted from a stale snapshot.
            let validation = holoscape_validate_process_group_session(
                processGroupID,
                processIdentifier
            )
            if validation < 0 { return -validation }
            if validation == 0 { continue }
            let signalError = signalProcessGroup(processGroupID, signal)
            if signalError != 0, signalError != ESRCH { return signalError }
        }
        return 0
    }

    private func killLiveSessionProcessGroupsUntilExit(
        signalProcessGroup: @Sendable (pid_t, Int32) -> Int32,
        timeoutMilliseconds: Int
    ) -> Int32? {
        let deadline = DispatchTime.now() + .milliseconds(timeoutMilliseconds)
        while true {
            let snapshot = copyLiveSessionProcessGroups()
            if let snapshotError = snapshot.error { return snapshotError }
            if snapshot.groups.isEmpty { return nil }
            let signalError = signalValidatedProcessGroups(
                snapshot.groups,
                signal: SIGKILL,
                signalProcessGroup: signalProcessGroup
            )
            if signalError != 0 { return signalError }
            if DispatchTime.now() >= deadline {
                return ETIMEDOUT
            }
            usleep(10_000)
        }
    }

    static func launch(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?,
        size: TerminalGridSize,
        waiter: @escaping Waiter,
        reaper: @escaping Reaper
    ) throws -> (process: NativePTYChildProcess, processGroupID: pid_t, masterDescriptor: Int32) {
        let argumentPointers = ([executable] + arguments).map { strdup($0) } + [nil]
        let environmentPointers = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let workingDirectoryPointer: UnsafeMutablePointer<CChar>? = workingDirectory.flatMap { strdup($0) }
        defer {
            argumentPointers.compactMap { $0 }.forEach { free($0) }
            environmentPointers.compactMap { $0 }.forEach { free($0) }
            workingDirectoryPointer.map { free($0) }
        }

        var childPID: pid_t = 0
        var processGroupID: pid_t = 0
        var masterDescriptor: Int32 = -1
        var cleanupPending: Int32 = 0
        let launchError = argumentPointers.withUnsafeBufferPointer { argv in
            environmentPointers.withUnsafeBufferPointer { envp in
                holoscape_spawn_pty(
                    argv[0],
                    UnsafeMutablePointer(mutating: argv.baseAddress),
                    UnsafeMutablePointer(mutating: envp.baseAddress),
                    workingDirectoryPointer,
                    UInt16(size.rows),
                    UInt16(size.columns),
                    &childPID,
                    &processGroupID,
                    &masterDescriptor,
                    &cleanupPending
                )
            }
        }
        guard launchError == 0 else {
            let retainedProcess: NativePTYChildProcess?
            if cleanupPending != 0, childPID > 0, processGroupID > 0, masterDescriptor >= 0 {
                retainedProcess = NativePTYChildProcess(
                    processIdentifier: childPID,
                    processGroupID: processGroupID,
                    masterDescriptor: masterDescriptor,
                    waiter: waiter,
                    reaper: reaper
                )
            } else {
                retainedProcess = nil
            }
            throw LaunchFailure(
                errno: launchError,
                masterDescriptor: masterDescriptor,
                process: retainedProcess
            )
        }
        return (
            NativePTYChildProcess(
                processIdentifier: childPID,
                processGroupID: processGroupID,
                masterDescriptor: masterDescriptor,
                waiter: waiter,
                reaper: reaper
            ),
            processGroupID,
            masterDescriptor
        )
    }
}

/// In-process native PTY runtime for the first broker-backed local sessions.
///
/// This is still not the final out-of-process survival broker. It deliberately
/// owns a real PTY/process pair behind `BrokerSessionRuntime`, which lets the
/// coordinator facade exercise launch, input/output, resize, and termination
/// semantics before the process host is moved outside the UI app.
final class NativePTYBrokerSessionRuntime: BrokerSessionRuntime, BrokerSessionInputInterruptingRuntime, BrokerSessionAgentStatusOwnerTokenAcknowledgingRuntime, ScrollbackReplayReportingRuntime, BrokerOutputAvailabilityMonitoringRuntime, BrokerTransactionalOutputRuntime, @unchecked Sendable {
    enum InputDescriptorCloseResult: Equatable, Sendable {
        case closed
        case closedWithWarning(Int32)
        case ownershipRetained(Int32)
    }

    enum RuntimeError: Error, Equatable {
        case duplicateSession(BrokerSessionID)
        case missingSession(BrokerSessionID)
        case openPTYFailed(errno: Int32)
        case launchFailed(String)
        case launchCleanupPending(BrokerSessionID, reason: String)
        case launchFailedWithInputCloseFailure(reason: String, errno: Int32)
        case invalidGridSize(TerminalGridSize)
        case resizeFailed(errno: Int32)
        case inputWriteTimedOut(BrokerSessionID)
        case inputWriteFailed(BrokerSessionID, errno: Int32)
        case inputClosed(BrokerSessionID)
        case inputCloseFailed(BrokerSessionID, errno: Int32)
        case retirementCompletedWithInputCloseFailure(BrokerSessionID, errno: Int32)
        case retirementCompletedWithOutputFailure(BrokerSessionID, reason: String)
        case retirementFailed(BrokerSessionID, inputCloseErrno: Int32?, processFailure: String)
        case exitCompletedWithInputCloseFailure(
            BrokerSessionID,
            observedExitCode: Int32,
            inputCloseErrno: Int32,
            expectedExitCode: Int32?
        )
        case exitCodeMismatch(expected: Int32, observed: Int32)
        case terminationFailed(BrokerSessionID, reason: String)
        case outputMonitoringFailed(BrokerSessionID, reason: String)
        case scrollbackPersistenceFailed(BrokerSessionID, reason: String)
        case unsupportedEnvironmentProfile(BrokerEnvironmentProfile, reason: String)
    }

    private final class Session: @unchecked Sendable {
        private enum InputState {
            case open
            case closing
            case closed(warning: Int32?)
            case closeFailedOwnershipRetained(errno: Int32)
        }

        let id: BrokerSessionID
        let process: NativePTYChildProcess
        let masterHandle: FileHandle
        private let inputDescriptor: Int32
        private let inputWriteTimeoutMilliseconds: Int32
        private let inputDescriptorCloser: @Sendable (Int32) -> InputDescriptorCloseResult
        private let inputWriteDidStart: @Sendable (BrokerSessionID) -> Void
        private let outputReadDidStart: @Sendable (BrokerSessionID) -> Void
        private let outputReader: @Sendable (Int32, UnsafeMutableRawPointer?, Int) -> (count: Int, errno: Int32)
        private let installsOutputReadabilityHandler: Bool
        private let outputPersistenceQueue: DispatchQueue
        private let outputPersistenceGroup = DispatchGroup()
        private let outputCleanupTimeoutMilliseconds: Int
        let scrollbackAppender: (@Sendable (Data, BrokerSessionID) throws -> Void)?
        private var processGroupCleanupFailureReason: String?
        let lock = NSLock()
        private let inputStateCondition = NSCondition()
        private let inputWriteLock = NSLock()
        private let outputReadLock = NSLock()
        private let terminationLock = NSLock()
        private var inputState = InputState.open
        var output = Data()
        private var outputStartOffset: UInt64 = 0
        private var outputEndOffset: UInt64 = 0
        private var legacyReplayPresented = false
        var scrollback = Data()
        private var scrollbackPersistenceFailureReason: String?
        private var pendingScrollbackPersistenceData = Data()
        private var outputPersistenceBytesOutstanding = 0
        private var outputPersistenceWriteInFlight = false
        private var outputReadPausedForPersistence = false
        private var outputMonitoringShutdown = false
        private var outputMonitoringComplete = false
        private var outputMonitoringFailureReason: String?
        private var finalOutputDrainFailureReason: String?
        private var finalOutputDrainComplete = false
        var terminationStatus: Int32?
        private var processWaitFailureReason: String?
        var outputAvailabilityHandler: (@Sendable (BrokerSessionID) -> Void)?
        private let maxScrollbackBytes = ScrollbackPersistencePolicy.maxRetainedBytesPerSession

        init(
            id: BrokerSessionID,
            process: NativePTYChildProcess,
            masterHandle: FileHandle,
            inputDescriptor: Int32,
            inputWriteTimeoutMilliseconds: Int32,
            inputDescriptorCloser: @escaping @Sendable (Int32) -> InputDescriptorCloseResult,
            inputWriteDidStart: @escaping @Sendable (BrokerSessionID) -> Void,
            outputReadDidStart: @escaping @Sendable (BrokerSessionID) -> Void,
            outputReader: @escaping @Sendable (Int32, UnsafeMutableRawPointer?, Int) -> (count: Int, errno: Int32),
            installsOutputReadabilityHandler: Bool,
            outputCleanupTimeoutMilliseconds: Int,
            scrollbackAppender: (@Sendable (Data, BrokerSessionID) throws -> Void)?
        ) {
            self.id = id
            self.process = process
            self.masterHandle = masterHandle
            self.inputDescriptor = inputDescriptor
            self.inputWriteTimeoutMilliseconds = inputWriteTimeoutMilliseconds
            self.inputDescriptorCloser = inputDescriptorCloser
            self.inputWriteDidStart = inputWriteDidStart
            self.outputReadDidStart = outputReadDidStart
            self.outputReader = outputReader
            self.installsOutputReadabilityHandler = installsOutputReadabilityHandler
            self.outputPersistenceQueue = DispatchQueue(
                label: "com.holoscape.broker-session-output-persistence.\(id.rawValue)"
            )
            self.outputCleanupTimeoutMilliseconds = max(1, outputCleanupTimeoutMilliseconds)
            self.scrollbackAppender = scrollbackAppender
        }

        deinit {
            do {
                try closeInput()
            } catch {
                NSLog("Native PTY input descriptor cleanup failed for \(id.rawValue): \(error)")
            }
        }

        func appendOutput(_ data: Data) {
            var persistenceWrite: Data?
            var shouldSignalWithoutPersistence = false
            lock.lock()
            output.append(data)
            outputEndOffset &+= UInt64(data.count)
            scrollback.append(data)
            if scrollback.count > maxScrollbackBytes {
                scrollback.removeFirst(scrollback.count - maxScrollbackBytes)
            }
            if scrollbackAppender != nil && scrollbackPersistenceFailureReason == nil {
                pendingScrollbackPersistenceData.append(data)
                outputPersistenceBytesOutstanding += data.count
                if !outputPersistenceWriteInFlight {
                    outputPersistenceWriteInFlight = true
                    persistenceWrite = pendingScrollbackPersistenceData
                    pendingScrollbackPersistenceData.removeAll(keepingCapacity: false)
                }
            } else {
                shouldSignalWithoutPersistence = true
            }
            lock.unlock()
            guard let persistenceWrite else {
                if shouldSignalWithoutPersistence {
                    signalOutputAvailability()
                }
                return
            }
            schedulePersistenceWrite(persistenceWrite)
        }

        private func schedulePersistenceWrite(_ data: Data) {
            guard let scrollbackAppender else {
                signalOutputAvailability()
                return
            }
            outputPersistenceGroup.enter()
            let group = outputPersistenceGroup
            let id = id
            outputPersistenceQueue.async { [weak self, scrollbackAppender, data, id, group] in
                var failureReason: String?
                do {
                    try scrollbackAppender(data, id)
                } catch {
                    failureReason = String(describing: error)
                }
                self?.completePersistenceWrite(byteCount: data.count, failureReason: failureReason)
                group.leave()
            }
        }

        private func completePersistenceWrite(byteCount: Int, failureReason: String?) {
            var nextWrite: Data?
            var shouldResumeOutputRead = false
            lock.lock()
            outputPersistenceBytesOutstanding = max(0, outputPersistenceBytesOutstanding - byteCount)
            if let failureReason {
                if scrollbackPersistenceFailureReason == nil {
                    scrollbackPersistenceFailureReason = failureReason
                }
                outputPersistenceBytesOutstanding = 0
                pendingScrollbackPersistenceData.removeAll(keepingCapacity: false)
                outputPersistenceWriteInFlight = false
            } else if !pendingScrollbackPersistenceData.isEmpty {
                nextWrite = pendingScrollbackPersistenceData
                pendingScrollbackPersistenceData.removeAll(keepingCapacity: false)
            } else {
                outputPersistenceWriteInFlight = false
            }
            if outputReadPausedForPersistence,
               scrollbackPersistenceFailureReason == nil,
               outputPersistenceBytesOutstanding < maxScrollbackBytes,
               !finalOutputDrainComplete,
               !outputMonitoringShutdown,
               !outputMonitoringComplete {
                outputReadPausedForPersistence = false
                shouldResumeOutputRead = true
            }
            lock.unlock()

            if let failureReason {
                NSLog("Broker scrollback persistence failed for \(id.rawValue): \(failureReason)")
            }
            if let nextWrite {
                schedulePersistenceWrite(nextWrite)
            }
            if shouldResumeOutputRead {
                startOutputMonitoring()
            }
            signalOutputAvailability()
        }

        private func signalOutputAvailability() {
            // Wake readers only after persistence has either succeeded or its
            // failure has been retained, so the first awakened read cannot race
            // past a durability failure and leave the terminal looking healthy.
            lock.lock()
            let handler = outputAvailabilityHandler
            lock.unlock()
            handler?(id)
        }

        func startOutputMonitoring() {
            guard installsOutputReadabilityHandler else { return }
            outputReadLock.lock()
            defer { outputReadLock.unlock() }
            lock.lock()
            let shouldInstall = !outputMonitoringShutdown && !finalOutputDrainComplete
            lock.unlock()
            guard shouldInstall else { return }
            masterHandle.readabilityHandler = { [weak self] handle in
                guard let self else {
                    handle.readabilityHandler = nil
                    return
                }
                _ = self.consumeReadabilityEvent(from: handle)
            }
        }

        func consumeReadabilityEvent(from handle: FileHandle) -> Bool {
            outputReadLock.lock()
            defer { outputReadLock.unlock() }
            let drainState = finalOutputDrainState()
            lock.lock()
            let monitoringShutdown = outputMonitoringShutdown
            lock.unlock()
            guard !monitoringShutdown, !drainState.complete, drainState.failureReason == nil else {
                handle.readabilityHandler = nil
                return false
            }
            lock.lock()
            let persistenceFailed = scrollbackPersistenceFailureReason != nil
            let readCapacity = scrollbackAppender == nil || persistenceFailed
                ? 64 * 1_024
                : min(64 * 1_024, max(0, maxScrollbackBytes - outputPersistenceBytesOutstanding))
            if readCapacity == 0 {
                outputReadPausedForPersistence = true
            }
            lock.unlock()
            if readCapacity == 0 {
                handle.readabilityHandler = nil
                return true
            }
            outputReadDidStart(id)
            var buffer = [UInt8](repeating: 0, count: readCapacity)
            let readResult = buffer.withUnsafeMutableBytes { rawBuffer in
                outputReader(handle.fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            let count = readResult.count
            if count > 0 {
                appendOutput(Data(buffer.prefix(count)))
                return true
            }
            if count == 0 || readResult.errno == EIO {
                markOutputMonitoringComplete()
                handle.readabilityHandler = nil
                return false
            }
            if readResult.errno == EINTR || readResult.errno == EAGAIN || readResult.errno == EWOULDBLOCK {
                return true
            }
            let failureReason = "PTY readability drain failed: \(String(cString: strerror(readResult.errno)))"
            lock.lock()
            outputMonitoringFailureReason = failureReason
            finalOutputDrainFailureReason = failureReason
            lock.unlock()
            markOutputMonitoringComplete()
            signalOutputAvailability()
            handle.readabilityHandler = nil
            return false
        }

        private func persistenceReadCapacity(maxBytes: Int) -> Int {
            lock.lock()
            defer { lock.unlock() }
            guard scrollbackAppender != nil, scrollbackPersistenceFailureReason == nil else {
                return maxBytes
            }
            return min(maxBytes, max(0, maxScrollbackBytes - outputPersistenceBytesOutstanding))
        }

        func drainBufferedOutputBeforeTermination() throws {
            outputReadLock.lock()
            defer { outputReadLock.unlock() }
            let drainState = finalOutputDrainState()
            if let reason = drainState.failureReason {
                throw RuntimeError.retirementCompletedWithOutputFailure(id, reason: reason)
            }
            guard !drainState.complete else {
                try throwScrollbackPersistenceErrorAsRetirementWarning()
                return
            }
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            let deadline = DispatchTime.now() + .milliseconds(outputCleanupTimeoutMilliseconds)
            var drainedByteCount = 0
            while true {
                if DispatchTime.now() >= deadline || drainedByteCount >= maxScrollbackBytes { return }
                let readCapacity = persistenceReadCapacity(maxBytes: buffer.count)
                if readCapacity == 0 {
                    try retainFinalOutputDrainFailure(
                        reason: "final PTY output persistence backlog reached the bounded retention limit"
                    )
                }
                var descriptor = pollfd(fd: masterHandle.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                let ready = poll(&descriptor, 1, 0)
                if ready == 0 {
                    return
                }
                if ready < 0 {
                    if errno == EINTR { continue }
                    try retainFinalOutputDrainFailure(errno: errno)
                }
                let readResult = buffer.withUnsafeMutableBytes { rawBuffer in
                    outputReader(masterHandle.fileDescriptor, rawBuffer.baseAddress, readCapacity)
                }
                let count = readResult.count
                if count > 0 {
                    drainedByteCount += count
                    appendOutput(Data(buffer.prefix(count)))
                    continue
                }
                if count == 0 || readResult.errno == EIO {
                    return
                }
                if readResult.errno == EINTR {
                    continue
                }
                try retainFinalOutputDrainFailure(errno: readResult.errno)
            }
        }

        func drainFinalOutput() throws {
            outputReadLock.lock()
            defer { outputReadLock.unlock() }
            let drainState = finalOutputDrainState()
            if let reason = drainState.failureReason {
                throw RuntimeError.retirementCompletedWithOutputFailure(id, reason: reason)
            }
            guard !drainState.complete else {
                try throwScrollbackPersistenceErrorAsRetirementWarning()
                return
            }

            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            let deadline = DispatchTime.now() + .milliseconds(outputCleanupTimeoutMilliseconds)
            var drainedByteCount = 0
            while true {
                if DispatchTime.now() >= deadline {
                    try retainFinalOutputDrainFailure(reason: "final PTY output drain timed out")
                }
                if drainedByteCount >= maxScrollbackBytes {
                    try retainFinalOutputDrainFailure(reason: "final PTY output exceeded the bounded drain limit")
                }
                let readCapacity = persistenceReadCapacity(maxBytes: buffer.count)
                if readCapacity == 0 {
                    try retainFinalOutputDrainFailure(
                        reason: "final PTY output persistence backlog reached the bounded retention limit"
                    )
                }
                var descriptor = pollfd(fd: masterHandle.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                let ready = poll(&descriptor, 1, 0)
                if ready == 0 {
                    break
                }
                if ready < 0 {
                    if errno == EINTR { continue }
                    try retainFinalOutputDrainFailure(errno: errno)
                }
                let readResult = buffer.withUnsafeMutableBytes { rawBuffer in
                    outputReader(masterHandle.fileDescriptor, rawBuffer.baseAddress, readCapacity)
                }
                let count = readResult.count
                if count > 0 {
                    drainedByteCount += count
                    appendOutput(Data(buffer.prefix(count)))
                    continue
                }
                if count == 0 || readResult.errno == EIO {
                    break
                }
                if readResult.errno == EINTR {
                    continue
                }
                try retainFinalOutputDrainFailure(errno: readResult.errno)
            }
            lock.lock()
            finalOutputDrainComplete = true
            lock.unlock()
            markOutputMonitoringComplete()
            guard outputPersistenceGroup.wait(timeout: deadline) == .success else {
                try retainFinalOutputDrainFailure(reason: "final PTY output persistence timed out")
            }
            try throwScrollbackPersistenceErrorAsRetirementWarning()
        }

        private func retainFinalOutputDrainFailure(errno: Int32) throws -> Never {
            try retainFinalOutputDrainFailure(
                reason: "final PTY output drain failed: \(String(cString: strerror(errno)))"
            )
        }

        private func retainFinalOutputDrainFailure(reason: String) throws -> Never {
            lock.lock()
            finalOutputDrainFailureReason = reason
            lock.unlock()
            throw RuntimeError.retirementCompletedWithOutputFailure(id, reason: reason)
        }

        private func finalOutputDrainState() -> (complete: Bool, failureReason: String?) {
            lock.lock()
            defer { lock.unlock() }
            return (finalOutputDrainComplete, finalOutputDrainFailureReason)
        }

        func throwOutputMonitoringErrorIfPresent() throws {
            lock.lock()
            let failureReason = outputMonitoringFailureReason
            lock.unlock()
            if let failureReason {
                throw RuntimeError.outputMonitoringFailed(id, reason: failureReason)
            }
        }

        private func throwScrollbackPersistenceErrorAsRetirementWarning() throws {
            do {
                try throwScrollbackPersistenceErrorIfPresent()
            } catch {
                let reason = String(describing: error)
                lock.lock()
                finalOutputDrainFailureReason = reason
                lock.unlock()
                throw RuntimeError.retirementCompletedWithOutputFailure(id, reason: reason)
            }
        }

        func snapshotOutput(maxBytes: Int) throws -> BrokerOutputSnapshot {
            lock.lock()
            if let reason = outputMonitoringFailureReason {
                lock.unlock()
                throw RuntimeError.outputMonitoringFailed(id, reason: reason)
            }
            if let reason = scrollbackPersistenceFailureReason {
                lock.unlock()
                throw RuntimeError.scrollbackPersistenceFailed(id, reason: reason)
            }
            guard outputPersistenceBytesOutstanding == 0 else {
                lock.unlock()
                return BrokerOutputSnapshot(data: Data(), generation: nil)
            }
            let boundedCount = min(max(0, maxBytes), output.count)
            let data = Data(output.prefix(boundedCount))
            let snapshot = BrokerOutputSnapshot(
                data: data,
                generation: data.isEmpty ? nil : outputStartOffset + UInt64(data.count)
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
            if let reason = outputMonitoringFailureReason {
                throw RuntimeError.outputMonitoringFailed(id, reason: reason)
            }
            if let reason = scrollbackPersistenceFailureReason {
                throw RuntimeError.scrollbackPersistenceFailed(id, reason: reason)
            }
            guard outputPersistenceBytesOutstanding == 0 else { return Data() }
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
            guard outputPersistenceBytesOutstanding == 0,
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
            guard outputPersistenceBytesOutstanding == 0,
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
            guard !data.isEmpty else { return }
            inputWriteLock.lock()
            defer { inputWriteLock.unlock() }
            try throwIfInputClosed()
            inputWriteDidStart(id)

            let deadline = DispatchTime.now() + .milliseconds(Int(inputWriteTimeoutMilliseconds))
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    try throwIfInputClosed()
                    let remainingMilliseconds = millisecondsRemaining(until: deadline)
                    guard remainingMilliseconds > 0 else {
                        throw RuntimeError.inputWriteTimedOut(id)
                    }

                    var pollFD = pollfd(fd: inputDescriptor, events: Int16(POLLOUT), revents: 0)
                    let readyCount = poll(&pollFD, 1, min(remainingMilliseconds, 10))
                    if readyCount < 0 {
                        if errno == EINTR { continue }
                        try throwIfInputClosed()
                        throw RuntimeError.inputWriteFailed(id, errno: errno)
                    }
                    if readyCount == 0 { continue }

                    let writeCount = min(rawBuffer.count - offset, 4_096)
                    let wrote = Darwin.write(
                        inputDescriptor,
                        baseAddress.advanced(by: offset),
                        writeCount
                    )
                    if wrote > 0 {
                        offset += wrote
                        continue
                    }
                    if wrote < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                        continue
                    }
                    try throwIfInputClosed()
                    throw RuntimeError.inputWriteFailed(id, errno: wrote == 0 ? EIO : errno)
                }
            }
        }

        func closeInput() throws {
            inputStateCondition.lock()
            while case .closing = inputState {
                inputStateCondition.wait()
            }
            switch inputState {
            case .open, .closeFailedOwnershipRetained:
                inputState = .closing
                inputStateCondition.unlock()
            case let .closed(warning):
                inputStateCondition.unlock()
                if let warning {
                    throw RuntimeError.inputCloseFailed(id, errno: warning)
                }
                return
            case .closing:
                preconditionFailure("closing state must be resolved by the wait loop")
            }

            // Mark closing before waiting so an in-flight poll exits at its next
            // bounded interval. Holding the write lock while closing prevents
            // descriptor reuse from racing a final write.
            inputWriteLock.lock()
            let closeResult = inputDescriptorCloser(inputDescriptor)
            inputWriteLock.unlock()

            inputStateCondition.lock()
            switch closeResult {
            case .closed:
                inputState = .closed(warning: nil)
            case let .closedWithWarning(errno):
                inputState = .closed(warning: errno)
            case let .ownershipRetained(errno):
                inputState = .closeFailedOwnershipRetained(errno: errno)
            }
            inputStateCondition.broadcast()
            inputStateCondition.unlock()
            switch closeResult {
            case .closed:
                return
            case let .closedWithWarning(errno), let .ownershipRetained(errno):
                throw RuntimeError.inputCloseFailed(id, errno: errno)
            }
        }

        private func throwIfInputClosed() throws {
            inputStateCondition.lock()
            let closed: Bool
            switch inputState {
            case .open:
                closed = false
            case .closing, .closed, .closeFailedOwnershipRetained:
                closed = true
            }
            inputStateCondition.unlock()
            if closed {
                throw RuntimeError.inputClosed(id)
            }
        }

        private func millisecondsRemaining(until deadline: DispatchTime) -> Int32 {
            let now = DispatchTime.now().uptimeNanoseconds
            let deadlineNanoseconds = deadline.uptimeNanoseconds
            guard deadlineNanoseconds > now else { return 0 }
            let remaining = (deadlineNanoseconds - now + 999_999) / 1_000_000
            return Int32(min(remaining, UInt64(Int32.max)))
        }

        func markTerminated(_ status: Int32) {
            lock.lock()
            terminationStatus = status
            lock.unlock()
        }

        func handleProcessTermination(
            _ observation: NativePTYChildProcess.TerminationObservation
        ) {
            do {
                try closeInput()
            } catch {
                NSLog("Native PTY input descriptor cleanup failed for \(id.rawValue): \(error)")
            }
            terminationLock.lock()
            defer { terminationLock.unlock() }

            lock.lock()
            terminationStatus = observation.status
            processWaitFailureReason = observation.waitError.map {
                "process cleanup failed before leader reap: \(String(cString: strerror($0)))"
            }
            if observation.waitError == nil, process.cleanupIsComplete {
                processGroupCleanupFailureReason = nil
            } else {
                processGroupCleanupFailureReason =
                    "automatic descendant cleanup failed before leader reap: "
                    + String(cString: strerror(observation.waitError ?? EIO))
            }
            lock.unlock()
        }

        func updateProcessCleanupObservation(_ observation: NativePTYChildProcess.TerminationObservation) {
            lock.lock()
            terminationStatus = observation.status
            processWaitFailureReason = observation.waitError.map {
                "process cleanup failed before leader reap: \(String(cString: strerror($0)))"
            }
            if observation.waitError == nil, process.cleanupIsComplete {
                processGroupCleanupFailureReason = nil
            } else {
                processGroupCleanupFailureReason = observation.waitError.map {
                    "automatic descendant cleanup failed before leader reap: \(String(cString: strerror($0)))"
                }
            }
            lock.unlock()
        }

        func observedTerminationStatus(processFallback: Int32? = nil) throws -> Int32? {
            lock.lock()
            if let reason = scrollbackPersistenceFailureReason {
                lock.unlock()
                throw RuntimeError.scrollbackPersistenceFailed(id, reason: reason)
            }
            if let reason = processWaitFailureReason {
                lock.unlock()
                throw RuntimeError.terminationFailed(id, reason: reason)
            }
            guard outputMonitoringComplete, outputPersistenceBytesOutstanding == 0 else {
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

        func shutDownOutputMonitoring() {
            outputReadLock.lock()
            defer { outputReadLock.unlock() }
            lock.lock()
            outputMonitoringShutdown = true
            outputReadPausedForPersistence = false
            lock.unlock()
            masterHandle.readabilityHandler = nil
        }

        func setOutputAvailabilityHandler(_ handler: (@Sendable (BrokerSessionID) -> Void)?) {
            lock.lock()
            outputAvailabilityHandler = handler
            let shouldSignalImmediately = handler != nil && (
                (!output.isEmpty && outputPersistenceBytesOutstanding == 0)
                    || scrollbackPersistenceFailureReason != nil
                    || outputMonitoringComplete
            )
            lock.unlock()
            if shouldSignalImmediately {
                handler?(id)
            }
        }

        func persistenceBacklogByteCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return outputPersistenceBytesOutstanding
        }

        func hasPendingScrollbackPersistence() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return outputPersistenceBytesOutstanding > 0 || outputPersistenceWriteInFlight
        }

        func observedProcessGroupCleanupFailureReason() -> String? {
            lock.lock()
            let reason = processGroupCleanupFailureReason
            lock.unlock()
            return reason
        }

        func retainProcessGroupCleanupFailure(_ reason: String) {
            lock.lock()
            processGroupCleanupFailureReason = reason
            lock.unlock()
        }

        func throwInputCloseErrorIfPresent(waitForClosing: Bool = false) throws {
            inputStateCondition.lock()
            while waitForClosing, case .closing = inputState {
                inputStateCondition.wait()
            }
            let closeError: Int32?
            switch inputState {
            case let .closed(warning):
                closeError = warning
            case let .closeFailedOwnershipRetained(errno):
                closeError = errno
            case .open, .closing:
                closeError = nil
            }
            inputStateCondition.unlock()
            if let closeError {
                throw RuntimeError.inputCloseFailed(id, errno: closeError)
            }
        }

        func inputDescriptorOwnershipIsRetained() -> Bool {
            inputStateCondition.lock()
            defer { inputStateCondition.unlock() }
            if case .closeFailedOwnershipRetained = inputState { return true }
            return false
        }

        func withTerminationLock<T>(_ body: () throws -> T) rethrows -> T {
            terminationLock.lock()
            defer { terminationLock.unlock() }
            return try body()
        }
    }

    private let lock = NSLock()
    private var sessions: [BrokerSessionID: Session] = [:]
    private final class RetainedLaunchCleanup {
        let process: NativePTYChildProcess

        init(process: NativePTYChildProcess) {
            self.process = process
        }
    }
    private var retainedLaunchCleanups: [BrokerSessionID: RetainedLaunchCleanup] = [:]
    private var retainedLaunchFailureInputDescriptors: [Int32] = []
    private let scrollbackStore: DiskBackedScrollbackStore?
    private let scrollbackAppender: (@Sendable (Data, BrokerSessionID) throws -> Void)?
    private let processEnvironment: [String: String]
    private let childProcessWaiter: NativePTYChildProcess.Waiter
    private let childProcessReaper: NativePTYChildProcess.Reaper
    private let processGroupSignal: @Sendable (pid_t, Int32) -> Int32
    private let processGroupLookup: @Sendable (pid_t) -> (processGroupID: pid_t, errno: Int32?)
    private let inputWriteTimeoutMilliseconds: Int32
    private let inputDescriptorDuplicator: @Sendable (Int32) -> (descriptor: Int32, errno: Int32?)
    private let inputDescriptorCloser: @Sendable (Int32) -> InputDescriptorCloseResult
    private let inputWriteDidStart: @Sendable (BrokerSessionID) -> Void
    private let outputReadDidStart: @Sendable (BrokerSessionID) -> Void
    private let outputReader: @Sendable (Int32, UnsafeMutableRawPointer?, Int) -> (count: Int, errno: Int32)
    private let outputCleanupTimeoutMilliseconds: Int
    private let installsOutputReadabilityHandler: Bool
    private static let terminationGracePeriodMilliseconds = 500

    init(
        scrollbackDirectory: URL? = nil,
        scrollbackAppender: (@Sendable (Data, BrokerSessionID) throws -> Void)? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        inputWriteTimeoutMilliseconds: Int32 = 1_000,
        inputDescriptorDuplicator: @escaping @Sendable (Int32) -> (descriptor: Int32, errno: Int32?) = { descriptor in
            let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            return (duplicate, duplicate < 0 ? errno : nil)
        },
        inputDescriptorCloser: @escaping @Sendable (Int32) -> InputDescriptorCloseResult = { descriptor in
            Darwin.close(descriptor) == 0 ? .closed : .ownershipRetained(errno)
        },
        inputWriteDidStart: @escaping @Sendable (BrokerSessionID) -> Void = { _ in },
        outputReadDidStart: @escaping @Sendable (BrokerSessionID) -> Void = { _ in },
        outputCleanupTimeoutMilliseconds: Int = 500,
        installsOutputReadabilityHandler: Bool = true,
        outputReader: @escaping @Sendable (Int32, UnsafeMutableRawPointer?, Int) -> (count: Int, errno: Int32) = { descriptor, buffer, count in
            let readCount = Darwin.read(descriptor, buffer, count)
            return (readCount, readCount < 0 ? errno : 0)
        },
        childProcessWaiter: @escaping NativePTYChildProcess.Waiter = { processIdentifier, sessionID, masterDescriptor in
            var foregroundProcessGroupID: pid_t = 0
            let waitError = holoscape_observe_pty_exit(
                processIdentifier,
                sessionID,
                masterDescriptor,
                &foregroundProcessGroupID
            )
            return NativePTYChildProcess.TerminationObservation(
                status: nil,
                waitError: waitError == 0 ? nil : waitError,
                foregroundProcessGroupID: foregroundProcessGroupID > 0 ? foregroundProcessGroupID : nil
            )
        },
        childProcessReaper: @escaping NativePTYChildProcess.Reaper = { processIdentifier in
            var observedStatus: Int32 = 0
            let waitError = holoscape_reap_pid(processIdentifier, &observedStatus)
            return NativePTYChildProcess.TerminationObservation(
                status: waitError == 0 ? observedStatus : nil,
                waitError: waitError == 0 ? nil : waitError,
                foregroundProcessGroupID: nil
            )
        },
        processGroupLookup: @escaping @Sendable (pid_t) -> (processGroupID: pid_t, errno: Int32?) = {
            ($0, nil)
        },
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
        self.inputWriteTimeoutMilliseconds = max(1, inputWriteTimeoutMilliseconds)
        self.inputDescriptorDuplicator = inputDescriptorDuplicator
        self.inputDescriptorCloser = inputDescriptorCloser
        self.inputWriteDidStart = inputWriteDidStart
        self.outputReadDidStart = outputReadDidStart
        self.outputReader = outputReader
        self.childProcessWaiter = childProcessWaiter
        self.childProcessReaper = childProcessReaper
        self.outputCleanupTimeoutMilliseconds = max(1, outputCleanupTimeoutMilliseconds)
        self.installsOutputReadabilityHandler = installsOutputReadabilityHandler
        self.processGroupLookup = processGroupLookup
        self.processGroupSignal = processGroupSignal
    }

    deinit {
        retainedLaunchFailureInputDescriptors.forEach { _ = Darwin.close($0) }
        for retained in retainedLaunchCleanups.values {
            _ = retained.process.signalOwnedProcessGroups(
                SIGKILL,
                signalProcessGroup: processGroupSignal
            )
            waitForCleanupCompletion(of: retained.process)
            if !retained.process.cleanupIsComplete, !retained.process.isRunning {
                _ = retained.process.retryObservedExitCleanup(
                    signalProcessGroup: processGroupSignal,
                    cleanupTimeoutMilliseconds: Self.terminationGracePeriodMilliseconds
                )
            }
        }
    }

    func listSessions() throws -> [BrokerSessionID] {
        lock.lock()
        // Failed-launch entries are cleanup authority, not attachable sessions,
        // but the broker inventory is also the relaunch recovery surface. Expose
        // their generated IDs so the coordinator can retire them as untracked
        // generations instead of launching a duplicate after an app restart.
        let ids = Set(sessions.keys)
            .union(retainedLaunchCleanups.keys)
            .sorted { $0.rawValue < $1.rawValue }
        lock.unlock()
        return ids
    }

    func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {
        lock.lock()
        defer { lock.unlock() }

        if sessions[id] != nil {
            throw RuntimeError.duplicateSession(id)
        }
        try retryRetainedLaunchCleanup(id: id)
        retryRetainedLaunchFailureInputDescriptorClosures()

        try validatePTYGridSize(request.initialSize)
        var resolvedEnvironment = try environment(for: request.environmentProfile)
        if request.environmentProfile == .agentOAuth || request.environmentProfile == .agentAPI,
           let ownerToken = request.agentStatusOwnerToken,
           !ownerToken.isEmpty {
            resolvedEnvironment["HOLOSCAPE_AGENT_STATUS_OWNER_TOKEN"] = ownerToken
        }

        let launch: (process: NativePTYChildProcess, processGroupID: pid_t, masterDescriptor: Int32)
        do {
            launch = try NativePTYChildProcess.launch(
                executable: request.command,
                arguments: request.arguments,
                environment: resolvedEnvironment,
                workingDirectory: request.workingDirectory,
                size: request.initialSize,
                waiter: childProcessWaiter,
                reaper: childProcessReaper
            )
        } catch let failure as NativePTYChildProcess.LaunchFailure {
            if let process = failure.process {
                try cleanUpFailedLaunch(
                    id: id,
                    process: process,
                    masterDescriptor: failure.masterDescriptor,
                    reason: "native PTY launch failed: \(String(cString: strerror(failure.errno)))"
                )
                throw RuntimeError.launchFailed(String(cString: strerror(failure.errno)))
            }
            let duplication = inputDescriptorDuplicator(failure.masterDescriptor)
            let inputDescriptor = duplication.descriptor
            let duplicationError = duplication.errno
            let closeResult = inputDescriptor >= 0
                ? inputDescriptorCloser(inputDescriptor)
                : nil
            _ = Darwin.close(failure.masterDescriptor)
            let reason = String(cString: strerror(failure.errno))
            switch closeResult {
            case let .ownershipRetained(closeErrno):
                retainedLaunchFailureInputDescriptors.append(inputDescriptor)
                throw RuntimeError.launchFailedWithInputCloseFailure(reason: reason, errno: closeErrno)
            case let .closedWithWarning(closeErrno):
                throw RuntimeError.launchFailedWithInputCloseFailure(reason: reason, errno: closeErrno)
            case .closed:
                throw RuntimeError.launchFailed(reason)
            case nil:
                throw RuntimeError.launchFailed(
                    duplicationError.map { "\(reason); PTY input duplication failed: \(String(cString: strerror($0)))" }
                        ?? reason
                )
            }
        }
        let process = launch.process
        let masterFD = launch.masterDescriptor

        let duplication = inputDescriptorDuplicator(masterFD)
        let inputDescriptor = duplication.descriptor
        guard inputDescriptor >= 0 else {
            let duplicationError = duplication.errno ?? EIO
            try cleanUpFailedLaunch(
                id: id,
                process: process,
                masterDescriptor: masterFD,
                reason: "PTY input duplication failed: \(String(cString: strerror(duplicationError)))"
            )
            throw RuntimeError.openPTYFailed(errno: duplicationError)
        }
        let descriptorFlags = fcntl(inputDescriptor, F_GETFL)
        guard descriptorFlags >= 0, fcntl(inputDescriptor, F_SETFL, descriptorFlags | O_NONBLOCK) == 0 else {
            let configurationError = errno
            _ = Darwin.close(inputDescriptor)
            try cleanUpFailedLaunch(
                id: id,
                process: process,
                masterDescriptor: masterFD,
                reason: "PTY input configuration failed: \(String(cString: strerror(configurationError)))"
            )
            throw RuntimeError.openPTYFailed(errno: configurationError)
        }

        let expectedProcessGroupID = launch.processGroupID
        let processGroupObservation = processGroupLookup(process.processIdentifier)
        if processGroupObservation.processGroupID != expectedProcessGroupID {
            let closeResult = inputDescriptorCloser(inputDescriptor)
            let inputCloseError: Error?
            switch closeResult {
            case .closed:
                inputCloseError = nil
            case let .closedWithWarning(closeErrno), let .ownershipRetained(closeErrno):
                if case .ownershipRetained = closeResult {
                    retainedLaunchFailureInputDescriptors.append(inputDescriptor)
                }
                inputCloseError = RuntimeError.inputCloseFailed(id, errno: closeErrno)
            }
            let observationReason = processGroupObservation.errno.map {
                String(cString: strerror($0))
            } ?? "observed process group \(processGroupObservation.processGroupID)"
            do {
                try cleanUpFailedLaunch(
                    id: id,
                    process: process,
                    masterDescriptor: masterFD,
                    reason: "PTY child process-group identity could not be established safely: \(observationReason)"
                )
            } catch let RuntimeError.launchCleanupPending(pendingID, cleanupReason) {
                let inputReason = inputCloseError.map { "; input cleanup also failed: \($0)" } ?? ""
                throw RuntimeError.launchCleanupPending(
                    pendingID,
                    reason: "\(cleanupReason)\(inputReason)"
                )
            } catch {
                throw combinedLaunchFailure(reason: String(describing: error), inputCloseError: inputCloseError)
            }
            throw combinedLaunchFailure(
                reason: "PTY child process-group identity could not be established safely: \(observationReason)",
                inputCloseError: inputCloseError
            )
        }
        let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        let session = Session(
            id: id,
            process: process,
            masterHandle: masterHandle,
            inputDescriptor: inputDescriptor,
            inputWriteTimeoutMilliseconds: inputWriteTimeoutMilliseconds,
            inputDescriptorCloser: inputDescriptorCloser,
            inputWriteDidStart: inputWriteDidStart,
            outputReadDidStart: outputReadDidStart,
            outputReader: outputReader,
            installsOutputReadabilityHandler: installsOutputReadabilityHandler,
            outputCleanupTimeoutMilliseconds: outputCleanupTimeoutMilliseconds,
            scrollbackAppender: scrollbackAppender
        )
        let processGroupSignal = self.processGroupSignal
        process.terminationHandler = { [weak session] process in
            session?.handleProcessTermination(process.terminationObservation)
        }
        if installsOutputReadabilityHandler {
            session.startOutputMonitoring()
        }
        // forkpty creates the session leader. WNOWAIT keeps that PID reserved as
        // session identity and cleanup authority until every same-session group
        // has disappeared and the leader is safely reaped.
        process.startWaiting(
            signalProcessGroup: processGroupSignal,
            cleanupTimeoutMilliseconds: Self.terminationGracePeriodMilliseconds
        )

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
        let inputCloseError = inputCloseFailure(for: session)
        do {
            try terminateBoundedly(session)
        } catch {
            throw combinedRetirementFailure(
                sessionID: id,
                inputCloseError: inputCloseError,
                processFailure: error
            )
        }
        let observation = session.process.terminationObservation
        if let waitError = observation.waitError {
            throw RuntimeError.terminationFailed(
                id,
                reason: "waitpid failed: \(String(cString: strerror(waitError)))"
            )
        }
        guard let observedExitCode = observation.status else {
            throw RuntimeError.terminationFailed(id, reason: "process stopped without a termination status")
        }
        session.markTerminated(observedExitCode)
        if case let RuntimeError.inputCloseFailed(_, closeErrno)? = inputCloseError {
            if session.inputDescriptorOwnershipIsRetained() {
                throw RuntimeError.retirementFailed(
                    id,
                    inputCloseErrno: closeErrno,
                    processFailure: "process exit completed; input descriptor cleanup remains pending"
                )
            }
            throw RuntimeError.exitCompletedWithInputCloseFailure(
                id,
                observedExitCode: observedExitCode,
                inputCloseErrno: closeErrno,
                expectedExitCode: exitCode
            )
        }
        if let exitCode, observedExitCode != exitCode {
            throw RuntimeError.exitCodeMismatch(expected: exitCode, observed: observedExitCode)
        }
    }

    func markSessionErrored(id: BrokerSessionID) throws {
        lock.lock()
        let isRetainedLaunchCleanup = retainedLaunchCleanups[id] != nil
        if isRetainedLaunchCleanup {
            defer { lock.unlock() }
            try retryRetainedLaunchCleanup(id: id)
            return
        }
        lock.unlock()

        let session = try session(for: id)
        do {
            try close(session)
            _ = try removeSession(id)
        } catch let RuntimeError.inputCloseFailed(_, closeErrno) {
            guard !session.inputDescriptorOwnershipIsRetained() else {
                throw RuntimeError.retirementFailed(
                    id,
                    inputCloseErrno: closeErrno,
                    processFailure: "process cleanup completed; input descriptor cleanup remains pending"
                )
            }
            // The closer proved the descriptor was retired despite its warning.
            _ = try removeSession(id)
            throw RuntimeError.retirementCompletedWithInputCloseFailure(id, errno: closeErrno)
        } catch let error as RuntimeError {
            if case .retirementCompletedWithOutputFailure = error {
                _ = try removeSession(id)
                throw error
            }
            if case .retirementFailed = error { throw error }
            throw RuntimeError.retirementFailed(
                id,
                inputCloseErrno: nil,
                processFailure: String(describing: error)
            )
        } catch {
            throw RuntimeError.retirementFailed(
                id,
                inputCloseErrno: nil,
                processFailure: String(describing: error)
            )
        }
    }

    func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {
        try session(for: id).writeInput(Data(bytes))
    }

    func interruptInput(id: BrokerSessionID) throws {
        // This is a pre-lane cancellation hint. The ordered lifecycle dispatch
        // remains authoritative for a missing session, including one created by
        // an already-admitted request that has not run yet.
        guard let session = existingSession(for: id) else { return }
        try session.closeInput()
    }

    func readAvailableOutput(id: BrokerSessionID) throws -> Data {
        try session(for: id).readOutput()
    }

    func snapshotAvailableOutput(id: BrokerSessionID, maxBytes: Int) throws -> BrokerOutputSnapshot {
        try session(for: id).snapshotOutput(maxBytes: maxBytes)
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

    @discardableResult
    func consumeOutputReadabilityEvent(id: BrokerSessionID) throws -> Bool {
        let session = try session(for: id)
        return session.consumeReadabilityEvent(from: session.masterHandle)
    }

    func outputPersistenceBacklogByteCount(id: BrokerSessionID) throws -> Int {
        try session(for: id).persistenceBacklogByteCount()
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
        try session.throwOutputMonitoringErrorIfPresent()
        if let waitError = session.process.terminationObservation.waitError {
            throw RuntimeError.terminationFailed(
                id,
                reason: "exit observation failed: \(String(cString: strerror(waitError)))"
            )
        }
        if !session.process.isRunning {
            return false
        }
        try session.throwInputCloseErrorIfPresent(waitForClosing: false)
        try session.throwScrollbackPersistenceErrorIfPresent()
        return true
    }

    func terminationStatus(id: BrokerSessionID) throws -> Int32? {
        let session = try session(for: id)
        try throwProcessGroupCleanupErrorIfPresent(for: session)
        try session.throwOutputMonitoringErrorIfPresent()
        if let waitError = session.process.terminationObservation.waitError {
            throw RuntimeError.terminationFailed(
                id,
                reason: "exit observation failed: \(String(cString: strerror(waitError)))"
            )
        }
        let processFallback = session.process.isRunning
            ? nil
            : session.process.terminationObservation.status
        let observedStatus = try session.observedTerminationStatus(processFallback: processFallback)
        if let observedStatus {
            do {
                try session.throwInputCloseErrorIfPresent(waitForClosing: true)
            } catch let RuntimeError.inputCloseFailed(_, closeErrno) {
                if session.inputDescriptorOwnershipIsRetained() {
                    throw RuntimeError.inputCloseFailed(id, errno: closeErrno)
                }
                throw RuntimeError.exitCompletedWithInputCloseFailure(
                    id,
                    observedExitCode: observedStatus,
                    inputCloseErrno: closeErrno,
                    expectedExitCode: nil
                )
            }
            return observedStatus
        }
        try session.throwInputCloseErrorIfPresent(waitForClosing: !session.process.isRunning)
        return nil
    }

    private func close(_ session: Session) throws {
        let inputCloseError = inputCloseFailure(for: session)
        var outputDrainError: Error?
        do {
            try session.drainBufferedOutputBeforeTermination()
        } catch {
            outputDrainError = error
        }
        do {
            try terminateBoundedly(session)
        } catch {
            if let outputDrainError {
                let closeErrno: Int32?
                if case let RuntimeError.inputCloseFailed(_, errno)? = inputCloseError {
                    closeErrno = errno
                } else {
                    closeErrno = nil
                }
                throw RuntimeError.retirementFailed(
                    session.id,
                    inputCloseErrno: closeErrno,
                    processFailure: "\(error); final output cleanup also failed: \(outputDrainError)"
                )
            }
            throw combinedRetirementFailure(
                sessionID: session.id,
                inputCloseError: inputCloseError,
                processFailure: error
            )
        }
        session.shutDownOutputMonitoring()
        do {
            try session.drainFinalOutput()
        } catch {
            if outputDrainError == nil {
                outputDrainError = error
            }
        }
        session.masterHandle.closeFile()
        session.setOutputAvailabilityHandler(nil)
        if let outputDrainError {
            let inputWarning = inputCloseError.map {
                "; input cleanup also reported: \(String(describing: $0))"
            } ?? ""
            if session.hasPendingScrollbackPersistence() {
                let closeErrno: Int32?
                if case let RuntimeError.inputCloseFailed(_, errno)? = inputCloseError {
                    closeErrno = errno
                } else {
                    closeErrno = nil
                }
                throw RuntimeError.retirementFailed(
                    session.id,
                    inputCloseErrno: closeErrno,
                    processFailure: "process cleanup completed; scrollback persistence remains pending: \(outputDrainError)"
                )
            }
            if session.inputDescriptorOwnershipIsRetained(),
               case let RuntimeError.inputCloseFailed(_, closeErrno)? = inputCloseError {
                throw RuntimeError.retirementFailed(
                    session.id,
                    inputCloseErrno: closeErrno,
                    processFailure: "process cleanup completed; final output cleanup failed: \(outputDrainError)"
                )
            }
            throw RuntimeError.retirementCompletedWithOutputFailure(
                session.id,
                reason: "\(String(describing: outputDrainError))\(inputWarning)"
            )
        }
        if let inputCloseError { throw inputCloseError }
    }

    private func combinedLaunchFailure(reason: String, inputCloseError: Error?) -> Error {
        guard case let RuntimeError.inputCloseFailed(_, closeErrno)? = inputCloseError else {
            return RuntimeError.launchFailed(reason)
        }
        return RuntimeError.launchFailedWithInputCloseFailure(reason: reason, errno: closeErrno)
    }

    private func combinedRetirementFailure(
        sessionID: BrokerSessionID,
        inputCloseError: Error?,
        processFailure: Error
    ) -> Error {
        guard case let RuntimeError.inputCloseFailed(_, closeErrno)? = inputCloseError else {
            return processFailure
        }
        return RuntimeError.retirementFailed(
            sessionID,
            inputCloseErrno: closeErrno,
            processFailure: String(describing: processFailure)
        )
    }

    private func retryRetainedLaunchFailureInputDescriptorClosures() {
        retainedLaunchFailureInputDescriptors = retainedLaunchFailureInputDescriptors.filter { descriptor in
            if case .ownershipRetained = inputDescriptorCloser(descriptor) {
                return true
            }
            return false
        }
    }

    private func cleanUpFailedLaunch(
        id: BrokerSessionID,
        process: NativePTYChildProcess,
        masterDescriptor: Int32,
        reason: String
    ) throws {
        retainedLaunchCleanups[id] = RetainedLaunchCleanup(process: process)
        process.retainMasterDescriptorUntilCleanupCompletes()
        process.startWaiting(
            signalProcessGroup: processGroupSignal,
            cleanupTimeoutMilliseconds: Self.terminationGracePeriodMilliseconds
        )
        let signalError = process.signalOwnedProcessGroups(
            SIGKILL,
            signalProcessGroup: processGroupSignal
        )
        if signalError == 0 {
            waitForCleanupCompletion(of: process)
        }
        if !process.cleanupIsComplete, !process.isRunning {
            _ = process.retryObservedExitCleanup(
                signalProcessGroup: processGroupSignal,
                cleanupTimeoutMilliseconds: Self.terminationGracePeriodMilliseconds
            )
        }
        guard process.cleanupIsComplete else {
            let cleanupReason = signalError == 0
                ? process.terminationObservation.waitError ?? ETIMEDOUT
                : signalError
            throw RuntimeError.launchCleanupPending(
                id,
                reason: "\(reason); launch cleanup remains retryable: \(String(cString: strerror(cleanupReason)))"
            )
        }
        retainedLaunchCleanups.removeValue(forKey: id)
    }

    private func retryRetainedLaunchCleanup(id: BrokerSessionID) throws {
        guard let retained = retainedLaunchCleanups[id] else { return }
        let signalError = retained.process.signalOwnedProcessGroups(
            SIGKILL,
            signalProcessGroup: processGroupSignal
        )
        if signalError == 0 {
            waitForCleanupCompletion(of: retained.process)
        }
        if !retained.process.cleanupIsComplete, !retained.process.isRunning {
            _ = retained.process.retryObservedExitCleanup(
                signalProcessGroup: processGroupSignal,
                cleanupTimeoutMilliseconds: Self.terminationGracePeriodMilliseconds
            )
        }
        guard retained.process.cleanupIsComplete else {
            let cleanupReason = signalError == 0
                ? retained.process.terminationObservation.waitError ?? ETIMEDOUT
                : signalError
            throw RuntimeError.launchCleanupPending(
                id,
                reason: "previous launch cleanup remains retryable: \(String(cString: strerror(cleanupReason)))"
            )
        }
        retainedLaunchCleanups.removeValue(forKey: id)
    }

    private func waitForCleanupCompletion(of process: NativePTYChildProcess) {
        let deadline = DispatchTime.now() + .milliseconds(Self.terminationGracePeriodMilliseconds)
        while !process.cleanupIsComplete, DispatchTime.now() < deadline {
            usleep(10_000)
        }
    }

    private func inputCloseFailure(for session: Session) -> Error? {
        do {
            try session.closeInput()
            return nil
        } catch {
            return error
        }
    }

    private func terminateBoundedly(_ session: Session) throws {
        try session.withTerminationLock {
            if session.process.cleanupIsComplete {
                return
            }

            if !session.process.isRunning {
                let retryObservation = session.process.retryObservedExitCleanup(
                    signalProcessGroup: processGroupSignal,
                    cleanupTimeoutMilliseconds: Self.terminationGracePeriodMilliseconds
                )
                session.updateProcessCleanupObservation(retryObservation)
                if session.process.cleanupIsComplete { return }
            }

            try signalOwnedProcessGroups(of: session, signal: SIGTERM)
            if waitForTermination(of: session.process) {
                return
            }

            try signalOwnedProcessGroups(of: session, signal: SIGKILL)
            guard waitForTermination(of: session.process) else {
                if !session.process.isRunning {
                    let retryObservation = session.process.retryObservedExitCleanup(
                        signalProcessGroup: processGroupSignal,
                        cleanupTimeoutMilliseconds: Self.terminationGracePeriodMilliseconds
                    )
                    session.updateProcessCleanupObservation(retryObservation)
                }
                guard !session.process.cleanupIsComplete else { return }
                let reason = "process/session cleanup remained pending after SIGTERM and SIGKILL"
                throw RuntimeError.terminationFailed(session.id, reason: reason)
            }
        }
    }

    private func throwProcessGroupCleanupErrorIfPresent(for session: Session) throws {
        guard let reason = session.observedProcessGroupCleanupFailureReason() else { return }
        throw RuntimeError.terminationFailed(session.id, reason: reason)
    }

    private func signalOwnedProcessGroups(
        of session: Session,
        signal: Int32
    ) throws {
        let signalError = session.process.signalOwnedProcessGroups(
            signal,
            signalProcessGroup: processGroupSignal
        )
        if signalError != 0, signalError != ESRCH {
            let reason = "signal \(signal) failed: \(String(cString: strerror(signalError)))"
            session.retainProcessGroupCleanupFailure(reason)
            throw RuntimeError.terminationFailed(session.id, reason: reason)
        }
    }

    private func waitForTermination(of process: NativePTYChildProcess) -> Bool {
        let deadline = DispatchTime.now() + .milliseconds(Self.terminationGracePeriodMilliseconds)
        while !process.cleanupIsComplete, DispatchTime.now() < deadline {
            usleep(10_000)
        }
        return process.cleanupIsComplete
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
