import Foundation

struct BrokerSessionCompositeFailure: Error, CustomStringConvertible, Sendable {
    let description: String
}

/// Bridges the output lane's exit observation to main-actor publication without
/// leaving a teardown window where both lanes can claim finalization authority.
final class BrokerExitResolutionClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var claimedSessionID: BrokerSessionID?

    func claimIfCurrent(
        _ sessionID: BrokerSessionID,
        closeCurrent: () -> Bool
    ) -> Bool {
        lock.withLock {
            guard claimedSessionID == nil, closeCurrent() else { return false }
            claimedSessionID = sessionID
            return true
        }
    }

    func joinOrStop(_ sessionID: BrokerSessionID, stop: () -> Void) -> Bool {
        lock.withLock {
            if claimedSessionID == sessionID { return true }
            stop()
            return false
        }
    }

    func consume(for sessionID: BrokerSessionID) -> Bool {
        lock.withLock {
            guard claimedSessionID == sessionID else { return false }
            claimedSessionID = nil
            return true
        }
    }
}

final class BrokerOutputReadLane: @unchecked Sendable {
    enum Mode {
        case outputAvailabilitySignal
        case periodicPolling
    }

    private let queue = DispatchQueue(label: "holoscape.broker.output.read-lane", qos: .userInteractive)
    private let signalTerminationCheckInterval: TimeInterval
    private let pollingInterval: TimeInterval
    private let lock = NSLock()
    private var openSessionID: BrokerSessionID?
    private var nextRunGeneration: UInt = 0
    private var openRunGeneration: UInt?
    private var closeAfterCurrentRunGeneration: UInt?
    private var semaphore: DispatchSemaphore?

    init(signalTerminationCheckInterval: TimeInterval = 1.0, pollingInterval: TimeInterval = 0.02) {
        self.signalTerminationCheckInterval = signalTerminationCheckInterval
        self.pollingInterval = pollingInterval
    }

    func start(
        sessionID: BrokerSessionID,
        mode: Mode,
        read: @escaping @Sendable (BrokerSessionID) throws -> BrokerOutputSnapshot,
        acknowledge: @escaping @Sendable (BrokerSessionID, UInt64) throws -> Void,
        terminationStatus: @escaping @Sendable (BrokerSessionID) throws -> Int32?,
        finishTermination: @escaping @Sendable (BrokerSessionID, Int32) throws -> Error?,
        exitResolutionClaim: BrokerExitResolutionClaim,
        onSample: @escaping @Sendable (BrokerSessionID, Data) -> Bool,
        onTermination: @escaping @Sendable (BrokerSessionID, Int32, Error?) -> Void,
        onFailure: @escaping @Sendable (BrokerSessionID, Int32?, Error, Data?) -> Void
    ) {
        stop()
        let semaphore = DispatchSemaphore(value: 0)
        let runGeneration = lock.withLock { () -> UInt in
            nextRunGeneration &+= 1
            openSessionID = sessionID
            openRunGeneration = nextRunGeneration
            closeAfterCurrentRunGeneration = nil
            self.semaphore = semaphore
            return nextRunGeneration
        }

        queue.async { [weak self] in
            semaphore.signal()
            while true {
                guard let self, self.isOpen(for: sessionID, runGeneration: runGeneration) else { return }
                switch mode {
                case .outputAvailabilitySignal:
                    _ = semaphore.wait(timeout: .now() + self.signalTerminationCheckInterval)
                case .periodicPolling:
                    _ = semaphore.wait(timeout: .now() + self.pollingInterval)
                }
                guard self.isOpen(for: sessionID, runGeneration: runGeneration) else { return }
                if self.closeWasRequested(for: sessionID, runGeneration: runGeneration) {
                    self.closeIfCurrent(sessionID, runGeneration: runGeneration)
                    return
                }
                var observedExitCode: Int32?
                var presentedUnacknowledgedData: Data?
                do {
                    let snapshot = try read(sessionID)
                    guard self.isOpen(for: sessionID, runGeneration: runGeneration) else { return }
                    guard onSample(sessionID, snapshot.data) else {
                        self.closeIfCurrent(sessionID, runGeneration: runGeneration)
                        return
                    }
                    if let generation = snapshot.generation {
                        presentedUnacknowledgedData = snapshot.data
                        try acknowledge(sessionID, generation)
                        presentedUnacknowledgedData = nil
                    }
                    guard self.isOpen(for: sessionID, runGeneration: runGeneration) else { return }
                    if let exitCode = try terminationStatus(sessionID) {
                        observedExitCode = exitCode
                        // Termination observation and the PTY readability callback
                        // can race. Once termination is observable, monitoring is
                        // complete, so one final drain captures bytes appended
                        // after the first read and before exit authority.
                        guard try self.drainRemainingOutput(
                            sessionID: sessionID,
                            runGeneration: runGeneration,
                            read: read,
                            acknowledge: acknowledge,
                            onSample: onSample
                        ) else { return }
                        // The final sample is synchronously consumed by the main
                        // actor before durable exit authority is published.
                        let completionWarning = try finishTermination(sessionID, exitCode)
                        if exitResolutionClaim.claimIfCurrent(
                            sessionID,
                            closeCurrent: {
                                self.closeIfCurrent(sessionID, runGeneration: runGeneration)
                            }
                        ) {
                            onTermination(sessionID, exitCode, completionWarning)
                        }
                        return
                    }
                    if self.closeWasRequested(for: sessionID, runGeneration: runGeneration) {
                        self.closeIfCurrent(sessionID, runGeneration: runGeneration)
                        return
                    }
                } catch {
                    let classified = self.classifyOutputFailure(
                        error,
                        observedExitCode: observedExitCode,
                        sessionID: sessionID,
                        terminationStatus: terminationStatus,
                        finishTermination: finishTermination
                    )
                    observedExitCode = classified.exitCode
                    let ownsOutcome: Bool
                    if observedExitCode != nil {
                        ownsOutcome = exitResolutionClaim.claimIfCurrent(
                            sessionID,
                            closeCurrent: {
                                self.closeIfCurrent(sessionID, runGeneration: runGeneration)
                            }
                        )
                    } else {
                        ownsOutcome = self.closeIfCurrent(sessionID, runGeneration: runGeneration)
                    }
                    if ownsOutcome {
                        onFailure(sessionID, observedExitCode, classified.error, presentedUnacknowledgedData)
                    }
                    return
                }
            }
        }
    }

    func pollOnce(
        sessionID: BrokerSessionID,
        read: @escaping @Sendable (BrokerSessionID) throws -> BrokerOutputSnapshot,
        acknowledge: @escaping @Sendable (BrokerSessionID, UInt64) throws -> Void,
        terminationStatus: @escaping @Sendable (BrokerSessionID) throws -> Int32?,
        finishTermination: @escaping @Sendable (BrokerSessionID, Int32) throws -> Error?,
        exitResolutionClaim: BrokerExitResolutionClaim,
        onSample: @escaping @Sendable (BrokerSessionID, Data) -> Bool,
        onTermination: @escaping @Sendable (BrokerSessionID, Int32, Error?) -> Void,
        onFailure: @escaping @Sendable (BrokerSessionID, Int32?, Error, Data?) -> Void
    ) {
        if isOpen(for: sessionID) {
            wake(sessionID: sessionID)
            return
        }
        let runGeneration = lock.withLock { () -> UInt in
            nextRunGeneration &+= 1
            openSessionID = sessionID
            openRunGeneration = nextRunGeneration
            closeAfterCurrentRunGeneration = nil
            semaphore = nil
            return nextRunGeneration
        }
        queue.async {
            var observedExitCode: Int32?
            var presentedUnacknowledgedData: Data?
            do {
                guard self.isOpen(for: sessionID, runGeneration: runGeneration) else { return }
                let snapshot = try read(sessionID)
                guard self.isOpen(for: sessionID, runGeneration: runGeneration) else { return }
                guard onSample(sessionID, snapshot.data) else {
                    self.closeIfCurrent(sessionID, runGeneration: runGeneration)
                    return
                }
                if let generation = snapshot.generation {
                    presentedUnacknowledgedData = snapshot.data
                    try acknowledge(sessionID, generation)
                    presentedUnacknowledgedData = nil
                }
                guard self.isOpen(for: sessionID, runGeneration: runGeneration) else { return }
                if let exitCode = try terminationStatus(sessionID) {
                    observedExitCode = exitCode
                    guard try self.drainRemainingOutput(
                        sessionID: sessionID,
                        runGeneration: runGeneration,
                        read: read,
                        acknowledge: acknowledge,
                        onSample: onSample
                    ) else { return }
                    let completionWarning = try finishTermination(sessionID, exitCode)
                    if exitResolutionClaim.claimIfCurrent(
                        sessionID,
                        closeCurrent: {
                            self.closeIfCurrent(sessionID, runGeneration: runGeneration)
                        }
                    ) {
                        onTermination(sessionID, exitCode, completionWarning)
                    }
                    return
                }
                self.closeIfCurrent(sessionID, runGeneration: runGeneration)
            } catch {
                let classified = self.classifyOutputFailure(
                    error,
                    observedExitCode: observedExitCode,
                    sessionID: sessionID,
                    terminationStatus: terminationStatus,
                    finishTermination: finishTermination
                )
                observedExitCode = classified.exitCode
                let ownsOutcome: Bool
                if observedExitCode != nil {
                    ownsOutcome = exitResolutionClaim.claimIfCurrent(
                        sessionID,
                        closeCurrent: {
                            self.closeIfCurrent(sessionID, runGeneration: runGeneration)
                        }
                    )
                } else {
                    ownsOutcome = self.closeIfCurrent(sessionID, runGeneration: runGeneration)
                }
                if ownsOutcome {
                    onFailure(sessionID, observedExitCode, classified.error, presentedUnacknowledgedData)
                }
            }
        }
    }

    private func classifyOutputFailure(
        _ originalError: Error,
        observedExitCode: Int32?,
        sessionID: BrokerSessionID,
        terminationStatus: @escaping @Sendable (BrokerSessionID) throws -> Int32?,
        finishTermination: @escaping @Sendable (BrokerSessionID, Int32) throws -> Error?
    ) -> (exitCode: Int32?, error: Error) {
        guard observedExitCode == nil else { return (observedExitCode, originalError) }
        do {
            guard let exitCode = try terminationStatus(sessionID) else {
                return (nil, originalError)
            }
            do {
                if let warning = try finishTermination(sessionID, exitCode) {
                    return (
                        exitCode,
                        BrokerSessionCompositeFailure(
                            description: "\(originalError); exit finalized with warning: \(warning)"
                        )
                    )
                }
                return (exitCode, originalError)
            } catch {
                return (
                    exitCode,
                    BrokerSessionCompositeFailure(
                        description: "\(originalError); failed to finalize observed exit: \(error)"
                    )
                )
            }
        } catch {
            // Status classification is best-effort when the broker itself is
            // unavailable. Preserve the original typed failure so controller
            // recovery guidance remains host-unavailable instead of degrading to
            // an unclassified composite.
            return (nil, originalError)
        }
    }

    /// Stop the ordinary pump and, on the same serial lane, determine whether
    /// teardown raced an already-completed child. Running sessions are left
    /// unread for later reattach; stopped sessions are fully drained and
    /// finalized before teardown can release its owner.
    func finishForTeardown(
        sessionID: BrokerSessionID,
        read: @escaping @Sendable (BrokerSessionID) throws -> BrokerOutputSnapshot,
        acknowledge: @escaping @Sendable (BrokerSessionID, UInt64) throws -> Void,
        terminationStatus: @escaping @Sendable (BrokerSessionID) throws -> Int32?,
        finishTermination: @escaping @Sendable (BrokerSessionID, Int32) throws -> Error?,
        onTermination: @escaping @Sendable (BrokerSessionID, Int32, Error?) -> Void,
        onStoppedFailure: @escaping @Sendable (BrokerSessionID, Int32, Error) -> Void,
        onStillRunningOrStatusFailure: @escaping @Sendable (Error?) -> Void
    ) {
        stop()
        queue.async {
            let exitCode: Int32
            do {
                guard let observedExitCode = try terminationStatus(sessionID) else {
                    onStillRunningOrStatusFailure(nil)
                    return
                }
                exitCode = observedExitCode
            } catch {
                onStillRunningOrStatusFailure(error)
                return
            }

            do {
                while true {
                    let snapshot = try read(sessionID)
                    guard let generation = snapshot.generation else { break }
                    try acknowledge(sessionID, generation)
                }
            } catch {
                let outputFailure = error
                do {
                    let completionWarning = try finishTermination(sessionID, exitCode)
                    if let completionWarning {
                        onStoppedFailure(
                            sessionID,
                            exitCode,
                            BrokerSessionCompositeFailure(
                                description: "\(outputFailure); exit finalized with warning: \(completionWarning)"
                            )
                        )
                    } else {
                        onStoppedFailure(sessionID, exitCode, outputFailure)
                    }
                } catch {
                    onStoppedFailure(
                        sessionID,
                        exitCode,
                        BrokerSessionCompositeFailure(
                            description: "\(outputFailure); failed to finalize observed exit: \(error)"
                        )
                    )
                }
                return
            }

            do {
                let completionWarning = try finishTermination(sessionID, exitCode)
                onTermination(sessionID, exitCode, completionWarning)
            } catch {
                onStoppedFailure(sessionID, exitCode, error)
            }
        }
    }

    /// Stop polling and run a barrier after any in-flight read/delivery has
    /// returned. Because `stop()` revokes the lane generation first, unread
    /// snapshots cannot be acknowledged while app termination detaches.
    func finishWithoutConsuming(completion: @escaping @Sendable () -> Void) {
        stop()
        queue.async(execute: completion)
    }

    /// Let the operation already executing on the lane classify and publish an
    /// exit failure before closing. This differs from app-termination teardown,
    /// which must revoke the generation immediately to preserve unread output.
    func finishForClose(completion: @escaping @Sendable () -> Void) {
        let semaphore = lock.withLock { () -> DispatchSemaphore? in
            guard openSessionID != nil, let openRunGeneration else { return nil }
            closeAfterCurrentRunGeneration = openRunGeneration
            return self.semaphore
        }
        semaphore?.signal()
        queue.async(execute: completion)
    }

    func wake(sessionID: BrokerSessionID) {
        guard isOpen(for: sessionID) else { return }
        lock.withLock { semaphore }?.signal()
    }

    func stop() {
        let semaphore = lock.withLock { () -> DispatchSemaphore? in
            openSessionID = nil
            openRunGeneration = nil
            closeAfterCurrentRunGeneration = nil
            let current = self.semaphore
            self.semaphore = nil
            return current
        }
        semaphore?.signal()
    }

    private func drainRemainingOutput(
        sessionID: BrokerSessionID,
        runGeneration: UInt,
        read: @escaping @Sendable (BrokerSessionID) throws -> BrokerOutputSnapshot,
        acknowledge: @escaping @Sendable (BrokerSessionID, UInt64) throws -> Void,
        onSample: @escaping @Sendable (BrokerSessionID, Data) -> Bool
    ) throws -> Bool {
        while isOpen(for: sessionID, runGeneration: runGeneration) {
            let snapshot = try read(sessionID)
            guard isOpen(for: sessionID, runGeneration: runGeneration) else { return false }
            guard onSample(sessionID, snapshot.data) else {
                closeIfCurrent(sessionID, runGeneration: runGeneration)
                return false
            }
            guard let generation = snapshot.generation else { return true }
            try acknowledge(sessionID, generation)
        }
        return false
    }

    private func isOpen(for sessionID: BrokerSessionID) -> Bool {
        lock.withLock { openSessionID == sessionID }
    }

    private func isOpen(for sessionID: BrokerSessionID, runGeneration: UInt) -> Bool {
        lock.withLock { openSessionID == sessionID && openRunGeneration == runGeneration }
    }

    private func closeWasRequested(for sessionID: BrokerSessionID, runGeneration: UInt) -> Bool {
        lock.withLock {
            openSessionID == sessionID
                && openRunGeneration == runGeneration
                && closeAfterCurrentRunGeneration == runGeneration
        }
    }


    @discardableResult
    private func closeIfCurrent(_ sessionID: BrokerSessionID, runGeneration: UInt) -> Bool {
        lock.withLock {
            if openSessionID == sessionID, openRunGeneration == runGeneration {
                openSessionID = nil
                openRunGeneration = nil
                closeAfterCurrentRunGeneration = nil
                semaphore?.signal()
                semaphore = nil
                return true
            }
            return false
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
