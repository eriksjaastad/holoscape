import Darwin
import Foundation

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
        let process: Process
        let masterHandle: FileHandle
        private let inputDescriptor: Int32
        private let inputWriteTimeoutMilliseconds: Int32
        private let inputDescriptorCloser: @Sendable (Int32) -> InputDescriptorCloseResult
        private let inputWriteDidStart: @Sendable (BrokerSessionID) -> Void
        private let outputReadDidStart: @Sendable (BrokerSessionID) -> Void
        private let installsOutputReadabilityHandler: Bool
        private let outputPersistenceQueue: DispatchQueue
        private let outputPersistenceGroup = DispatchGroup()
        private let outputCleanupTimeoutMilliseconds: Int
        let scrollbackAppender: (@Sendable (Data, BrokerSessionID) throws -> Void)?
        private var processGroupID: pid_t?
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
        private var outputMonitoringComplete = false
        private var finalOutputDrainFailureReason: String?
        private var finalOutputDrainComplete = false
        var terminationStatus: Int32?
        var outputAvailabilityHandler: (@Sendable (BrokerSessionID) -> Void)?
        private let maxScrollbackBytes = ScrollbackPersistencePolicy.maxRetainedBytesPerSession

        init(
            id: BrokerSessionID,
            process: Process,
            masterHandle: FileHandle,
            inputDescriptor: Int32,
            inputWriteTimeoutMilliseconds: Int32,
            inputDescriptorCloser: @escaping @Sendable (Int32) -> InputDescriptorCloseResult,
            inputWriteDidStart: @escaping @Sendable (BrokerSessionID) -> Void,
            outputReadDidStart: @escaping @Sendable (BrokerSessionID) -> Void,
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
            masterHandle.readabilityHandler = { [weak self] handle in
                guard self?.consumeReadabilityEvent(from: handle) == true else {
                    handle.readabilityHandler = nil
                    return
                }
            }
        }

        func consumeReadabilityEvent(from handle: FileHandle) -> Bool {
            outputReadLock.lock()
            defer { outputReadLock.unlock() }
            guard !finalOutputDrainComplete, finalOutputDrainFailureReason == nil else {
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
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(handle.fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 {
                appendOutput(Data(buffer.prefix(count)))
                return true
            }
            if count == 0 || errno == EIO {
                markOutputMonitoringComplete()
                return false
            }
            if errno == EINTR { return true }
            lock.lock()
            finalOutputDrainFailureReason = "PTY readability drain failed: \(String(cString: strerror(errno)))"
            lock.unlock()
            markOutputMonitoringComplete()
            signalOutputAvailability()
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
            if let reason = finalOutputDrainFailureReason {
                throw RuntimeError.retirementCompletedWithOutputFailure(id, reason: reason)
            }
            guard !finalOutputDrainComplete else {
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
                let count = buffer.withUnsafeMutableBytes { rawBuffer in
                    Darwin.read(masterHandle.fileDescriptor, rawBuffer.baseAddress, readCapacity)
                }
                if count > 0 {
                    drainedByteCount += count
                    appendOutput(Data(buffer.prefix(count)))
                    continue
                }
                if count == 0 || errno == EIO {
                    return
                }
                if errno == EINTR {
                    continue
                }
                try retainFinalOutputDrainFailure(errno: errno)
            }
        }

        func drainFinalOutput() throws {
            outputReadLock.lock()
            defer { outputReadLock.unlock() }
            if let reason = finalOutputDrainFailureReason {
                throw RuntimeError.retirementCompletedWithOutputFailure(id, reason: reason)
            }
            guard !finalOutputDrainComplete else {
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
                let count = buffer.withUnsafeMutableBytes { rawBuffer in
                    Darwin.read(masterHandle.fileDescriptor, rawBuffer.baseAddress, readCapacity)
                }
                if count > 0 {
                    drainedByteCount += count
                    appendOutput(Data(buffer.prefix(count)))
                    continue
                }
                if count == 0 || errno == EIO {
                    break
                }
                if errno == EINTR {
                    continue
                }
                try retainFinalOutputDrainFailure(errno: errno)
            }
            finalOutputDrainComplete = true
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
            finalOutputDrainFailureReason = reason
            throw RuntimeError.retirementCompletedWithOutputFailure(id, reason: reason)
        }

        private func throwScrollbackPersistenceErrorAsRetirementWarning() throws {
            do {
                try throwScrollbackPersistenceErrorIfPresent()
            } catch {
                let reason = String(describing: error)
                finalOutputDrainFailureReason = reason
                throw RuntimeError.retirementCompletedWithOutputFailure(id, reason: reason)
            }
        }

        func snapshotOutput(maxBytes: Int) throws -> BrokerOutputSnapshot {
            lock.lock()
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
            _ status: Int32,
            signalProcessGroup: @Sendable (pid_t, Int32) -> Int32
        ) {
            do {
                try closeInput()
            } catch {
                NSLog("Native PTY input descriptor cleanup failed for \(id.rawValue): \(error)")
            }
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
    private let inputWriteTimeoutMilliseconds: Int32
    private let inputDescriptorCloser: @Sendable (Int32) -> InputDescriptorCloseResult
    private let inputWriteDidStart: @Sendable (BrokerSessionID) -> Void
    private let outputReadDidStart: @Sendable (BrokerSessionID) -> Void
    private let outputCleanupTimeoutMilliseconds: Int
    private let installsOutputReadabilityHandler: Bool
    private static let terminationGracePeriodMilliseconds = 500

    init(
        scrollbackDirectory: URL? = nil,
        scrollbackAppender: (@Sendable (Data, BrokerSessionID) throws -> Void)? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        inputWriteTimeoutMilliseconds: Int32 = 1_000,
        inputDescriptorCloser: @escaping @Sendable (Int32) -> InputDescriptorCloseResult = { descriptor in
            Darwin.close(descriptor) == 0 ? .closed : .ownershipRetained(errno)
        },
        inputWriteDidStart: @escaping @Sendable (BrokerSessionID) -> Void = { _ in },
        outputReadDidStart: @escaping @Sendable (BrokerSessionID) -> Void = { _ in },
        outputCleanupTimeoutMilliseconds: Int = 500,
        installsOutputReadabilityHandler: Bool = true,
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
        self.inputDescriptorCloser = inputDescriptorCloser
        self.inputWriteDidStart = inputWriteDidStart
        self.outputReadDidStart = outputReadDidStart
        self.outputCleanupTimeoutMilliseconds = max(1, outputCleanupTimeoutMilliseconds)
        self.installsOutputReadabilityHandler = installsOutputReadabilityHandler
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

        let inputDescriptor = dup(masterFD)
        guard inputDescriptor >= 0 else {
            let duplicationError = errno
            _ = Darwin.close(masterFD)
            _ = Darwin.close(slaveFD)
            throw RuntimeError.openPTYFailed(errno: duplicationError)
        }
        let descriptorFlags = fcntl(inputDescriptor, F_GETFL)
        guard descriptorFlags >= 0, fcntl(inputDescriptor, F_SETFL, descriptorFlags | O_NONBLOCK) == 0 else {
            let configurationError = errno
            _ = Darwin.close(inputDescriptor)
            _ = Darwin.close(masterFD)
            _ = Darwin.close(slaveFD)
            throw RuntimeError.openPTYFailed(errno: configurationError)
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
            inputDescriptor: inputDescriptor,
            inputWriteTimeoutMilliseconds: inputWriteTimeoutMilliseconds,
            inputDescriptorCloser: inputDescriptorCloser,
            inputWriteDidStart: inputWriteDidStart,
            outputReadDidStart: outputReadDidStart,
            installsOutputReadabilityHandler: installsOutputReadabilityHandler,
            outputCleanupTimeoutMilliseconds: outputCleanupTimeoutMilliseconds,
            scrollbackAppender: scrollbackAppender
        )
        let processGroupSignal = self.processGroupSignal
        process.terminationHandler = { [weak session] process in
            session?.handleProcessTermination(
                process.terminationStatus,
                signalProcessGroup: processGroupSignal
            )
        }
        if installsOutputReadabilityHandler {
            session.startOutputMonitoring()
        }

        do {
            try process.run()
        } catch {
            masterHandle.readabilityHandler = nil
            let inputCloseError = inputCloseFailure(for: session)
            masterHandle.closeFile()
            slaveRead.closeFile()
            slaveWrite.closeFile()
            slaveError.closeFile()
            throw combinedLaunchFailure(
                reason: error.localizedDescription,
                inputCloseError: inputCloseError
            )
        }

        let expectedProcessGroupID = process.processIdentifier
        let observedProcessGroupID = getpgid(process.processIdentifier)
        if process.isRunning, observedProcessGroupID != expectedProcessGroupID {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            masterHandle.readabilityHandler = nil
            let inputCloseError = inputCloseFailure(for: session)
            masterHandle.closeFile()
            slaveRead.closeFile()
            slaveWrite.closeFile()
            slaveError.closeFile()
            throw combinedLaunchFailure(
                reason: "PTY child did not start in an isolated process group",
                inputCloseError: inputCloseError
            )
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
        let observedExitCode = session.process.terminationStatus
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
        if !session.process.isRunning { return false }
        try session.throwInputCloseErrorIfPresent(waitForClosing: false)
        try session.throwScrollbackPersistenceErrorIfPresent()
        return true
    }

    func terminationStatus(id: BrokerSessionID) throws -> Int32? {
        let session = try session(for: id)
        try throwProcessGroupCleanupErrorIfPresent(for: session)
        let processFallback = session.process.isRunning ? nil : session.process.terminationStatus
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
        session.masterHandle.readabilityHandler = nil
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
