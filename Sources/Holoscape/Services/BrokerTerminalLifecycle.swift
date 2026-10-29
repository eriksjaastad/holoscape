import Foundation

/// Keeps teardown ownership alive during an outage without hammering the
/// broker or registry at a fixed rate forever.
enum BrokerTeardownRetryPolicy {
    static let initialDelay: TimeInterval = 0.25
    static let maximumDelay: TimeInterval = 5

    static func delay(afterFailureCount failureCount: Int) -> TimeInterval {
        guard failureCount > 0 else { return initialDelay }
        let exponent = min(failureCount - 1, 30)
        return min(initialDelay * pow(2, Double(exponent)), maximumDelay)
    }
}

/// Which broker generation a failed launch leaves behind. Shared by the live
/// start path and the cancelled-launch cleanup so both read an ambiguous
/// outcome the same way.
enum BrokerLaunchFailure {
    /// Runtime and registry both hold the generation; only durability failed.
    case registryCommitted(BrokerSessionRecord)
    /// Creation may have committed at the broker; retry must reattach it.
    case outcomeUnknown(BrokerSessionRecord)
    /// The runtime holds a generation the durable registry does not track.
    case untracked(BrokerSessionID)
    case unattributed

    init(_ error: Error) {
        guard let coordinatorError = error as? BrokerSessionCoordinator.CoordinatorError else {
            self = .unattributed
            return
        }
        switch coordinatorError {
        case let .registryTransitionCommitted(record, _):
            self = .registryCommitted(record)
        case let .launchOutcomeUnknown(record, _):
            self = .outcomeUnknown(record)
        case let .untrackedSession(id, _, _):
            self = .untracked(id)
        default:
            self = .unattributed
        }
    }
}

/// Presentation and lane effects the lifecycle sequences but does not own.
/// The terminal process performs them; the lifecycle decides when, so close,
/// quit, outage, and stale-recovery ordering lives in one place.
@MainActor
protocol BrokerTerminalLifecycleHost: AnyObject, Sendable {
    var sessionFailure: TerminalSessionFailure? { get }
    func closeInputWrites()
    func markSessionIONotReady()
    /// Revokes the presentation lease and marks session I/O not ready.
    func revokeSessionPresentation()
    func stopOutputPump()
    func clearOutputAvailabilityHandler(for id: BrokerSessionID)
    func finishOutputLaneWithoutConsuming(_ completion: @escaping @Sendable () -> Void)
    func finishOutputLaneForClose(_ completion: @escaping @Sendable () -> Void)
    /// Joins an exit outcome the output lane already claimed; `false` stops
    /// the lane instead so nothing can claim one afterwards.
    func joinClaimedExitResolution(for id: BrokerSessionID) -> Bool
    var canProbeRunningSessionAtTeardown: Bool { get }
    func beginRunningSessionTeardownProbe(for id: BrokerSessionID)
    func publishSessionFailure(_ failure: TerminalSessionFailure)
    func publishStartCompletion()
}

/// Owns broker-session identity and retirement authority for one terminal:
/// launch/reattach state, stale and untracked generations, the joins that let
/// close, quit, and reconnect share a single teardown owner, retry of failed
/// retirement, and classification of runtime failures.
///
/// It never touches SwiftTerm or the output lane directly. Output presentation,
/// input wiring, and the final-drain-before-exit ordering stay with
/// `BrokerBackedTerminalProcess` and `BrokerOutputReadLane`.
@MainActor
final class BrokerTerminalLifecycle {
    private let coordinator: any BrokerSessionCoordinating
    private let recovery: BrokerFailureRecoveryCoordinator
    private let teardownRetryDelay: (Int) -> TimeInterval

    var brokerSessionID: BrokerSessionID?
    var agentStatusOwnerToken: String?
    /// Identity of the broker session this terminal failed to reattach because
    /// the broker no longer owns it. Kept separate from `brokerSessionID` so a
    /// retry spawns the replacement the stale guidance promises instead of
    /// reattaching the dead session, while the owning tab can still persist the
    /// dead identity for the next launch.
    var staleBrokerSessionID: BrokerSessionID?
    var untrackedBrokerSessionID: BrokerSessionID?
    var recoveringBrokerSessionID: BrokerSessionID?
    var startFailureDescription: String?
    var startFailureKind: TerminalStartFailureKind?
    /// Cleanup authority survives presentation-lease revocation. A retry resumes
    /// retirement instead of rendering unacknowledged final bytes again.
    var pendingExitedOutputRetirement: BrokerExitedOutputRetirement?
    var didNotifyTermination = false
    var startCompletionPending = false

    var freshStartPending = false
    var freshStartCancelled = false
    private var freshStartTeardownCompletions: [@MainActor () -> Void] = []
    /// A denied quit may reopen channel interaction while cancellation cleanup
    /// still owns an in-flight launch. Preserve the reconnect instead of leaving
    /// its controller waiting forever on the cancelled generation.
    private var restartAfterCancelledFreshStart: (@MainActor () -> Void)?
    var reattachGeneration: UInt = 0
    var reattachWorkInFlight = false
    var reattachWorkCompletionWaiters: [@MainActor () -> Void] = []
    /// App termination preserves unread broker output instead of allowing an
    /// in-flight restored-session drain to acknowledge and retire it unseen.
    private(set) var preservesUnreadOutputForTermination = false
    private var preservingOutputDetachInFlight = false
    private var preservingOutputDetachCompletions: [@MainActor (TerminalCleanupOutcome) -> Void] = []
    private var restartAfterPreservingOutputDetach: (@MainActor () -> Void)?
    /// Tab close owns terminal retirement through final output classification and
    /// persistence-facing cleanup truth. App termination must join that owner
    /// instead of independently stopping its output lane.
    private var closeRetirementInFlight = false
    private var closeRetirementCompletions: [@MainActor (TerminalCleanupOutcome) -> Void] = []
    var exitedOutputRetirementInFlight = false
    /// Covers the final read, acknowledgement, and any resulting retirement.
    /// Teardown waits for this authority to resolve instead of revoking the
    /// presentation lease and allowing the outcome to disappear with the tab.
    var exitedOutputResolutionInFlight = false
    var exitedOutputTeardownCompletions: [@MainActor (TerminalCleanupOutcome) -> Void] = []
    var runningSessionTeardownProbeInFlight = false
    private var restartAfterRunningSessionTeardown: (@MainActor () -> Void)?
    /// A denied quit can re-enable reconnect while exited-output cleanup still
    /// owns the old generation. Keep that activation pending until cleanup
    /// publishes its result rather than reporting the cleanup-only runtime active.
    var notifyStartAfterExitedOutputResolution = false

    init(
        coordinator: any BrokerSessionCoordinating,
        recovery: BrokerFailureRecoveryCoordinator,
        teardownRetryDelay: @escaping (Int) -> TimeInterval,
        brokerSessionID: BrokerSessionID?,
        pendingExitedOutputRetirement: BrokerExitedOutputRetirement?
    ) {
        self.coordinator = coordinator
        self.recovery = recovery
        self.teardownRetryDelay = teardownRetryDelay
        self.brokerSessionID = brokerSessionID
        self.pendingExitedOutputRetirement = pendingExitedOutputRetirement
    }

    // MARK: - Identity transitions

    func clearStartFailure() {
        startFailureDescription = nil
        startFailureKind = nil
        staleBrokerSessionID = nil
    }

    func recordStartFailure(_ error: Error) {
        startFailureDescription = String(describing: error)
        startFailureKind = Self.classifyStartFailure(error)
    }

    /// Takes ownership of a live generation after a successful start or reattach.
    func adopt(_ record: BrokerSessionRecord) {
        brokerSessionID = record.id
        agentStatusOwnerToken = record.agentStatusOwnerToken
        didNotifyTermination = false
    }

    /// Releases the tab's broker identity once the generation is retired.
    func clearIdentity() {
        brokerSessionID = nil
        agentStatusOwnerToken = nil
    }

    /// The broker no longer owns this generation: hand the dead identity to the
    /// tab and drop the live handle so retry starts a replacement.
    func markStale(_ id: BrokerSessionID) {
        brokerSessionID = nil
        staleBrokerSessionID = id
    }

    func recordLaunchFailure(_ failure: BrokerLaunchFailure) {
        switch failure {
        case .registryCommitted(let record), .outcomeUnknown(let record):
            // Preserve the exact generation so retry reattaches instead of
            // creating a duplicate, while still surfacing the failure.
            brokerSessionID = record.id
            agentStatusOwnerToken = record.agentStatusOwnerToken
        case .untracked(let id):
            untrackedBrokerSessionID = id
            clearIdentity()
        case .unattributed:
            clearIdentity()
        }
    }

    func recordReattachFailure(_ error: Error, sessionID: BrokerSessionID) {
        recordStartFailure(error)
        switch startFailureKind {
        case .brokerHostUnavailable:
            brokerSessionID = sessionID
        case .brokerSessionStale:
            markStale(sessionID)
        case .failed, .none:
            brokerSessionID = sessionID
        }
        agentStatusOwnerToken = nil
    }

    func retainExitedOutputRetirement(
        sessionID: BrokerSessionID,
        failureDescription: String,
        failureKind: TerminalStartFailureKind,
        observedExitCode: Int32? = nil
    ) {
        pendingExitedOutputRetirement = BrokerExitedOutputRetirement(
            sessionID: sessionID,
            outputFailureDescription: failureDescription,
            outputFailureKind: failureKind,
            observedExitCode: observedExitCode
        )
    }

    func currentCleanupOutcome() -> TerminalCleanupOutcome {
        guard pendingExitedOutputRetirement != nil else { return .completed }
        return .retryableFailure(TerminalSessionFailure(
            kind: startFailureKind ?? .failed,
            description: startFailureDescription ?? "Completed broker session retirement remains pending"
        ))
    }

    func cleanupFailure(from error: Error) -> TerminalSessionFailure {
        TerminalSessionFailure(
            kind: Self.classifyStartFailure(error),
            description: String(describing: error)
        )
    }

    /// Runs completed-session retirement where the coordinator requires it: on
    /// the recovery worker for host-backed runtimes, inline otherwise. Callers
    /// hop to the main actor themselves.
    func retireCompletedSession(
        _ id: BrokerSessionID,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        if coordinator.requiresOffMainBrokerWork {
            recovery.retireCompletedSession(id, completion: completion)
            return
        }
        do {
            try coordinator.retireCompletedSession(id)
            completion(nil)
        } catch {
            completion(error)
        }
    }

    // MARK: - Start gating

    /// Queues a start behind any teardown that still owns the session. Returns
    /// `true` when the start was deferred or absorbed; the caller must then
    /// return without launching.
    func deferStartIfTeardownOwnsSession(
        host: any BrokerTerminalLifecycleHost,
        reenter: @escaping @MainActor () -> Void,
        resumeAfterCancelledFreshStart: @escaping @MainActor () -> Void
    ) -> Bool {
        func restart(_ start: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
            { [weak self, weak host] in
                guard let self, let host else { return }
                startCompletionPending = false
                start()
                if !startCompletionPending {
                    host.publishStartCompletion()
                }
            }
        }
        if preservingOutputDetachInFlight {
            startCompletionPending = true
            restartAfterPreservingOutputDetach = restart(reenter)
            return true
        }
        if freshStartPending, freshStartCancelled {
            restartAfterCancelledFreshStart = restart(resumeAfterCancelledFreshStart)
            return true
        }
        if runningSessionTeardownProbeInFlight {
            startCompletionPending = true
            // Re-enter the complete start gate after teardown. The probe may
            // have discovered an exited session and published retryable
            // retirement authority while this reconnect was queued.
            restartAfterRunningSessionTeardown = restart(reenter)
            return true
        }
        if exitedOutputResolutionInFlight || exitedOutputRetirementInFlight {
            startCompletionPending = true
            notifyStartAfterExitedOutputResolution = true
            return true
        }
        return false
    }

    /// An untracked generation is outside the durable registry, so replacement
    /// cannot begin until retirement is confirmed. The caller always performs
    /// that potentially blocking cleanup off-main, including for in-process
    /// runtimes and test doubles that do not otherwise require host work.
    func retireUntrackedBeforeReplacement(
        _ id: BrokerSessionID,
        host: any BrokerTerminalLifecycleHost,
        replacement: @escaping @MainActor () -> Void
    ) {
        startCompletionPending = true
        recovery.retireUntrackedSession(id) { [weak self, weak host] error in
            DispatchQueue.main.async { [weak self, weak host] in
                guard let self, let host,
                      self.startCompletionPending,
                      self.untrackedBrokerSessionID == id else { return }
                if let error {
                    self.startFailureDescription = String(describing: error)
                    self.startFailureKind = .failed
                    NSLog("Broker-backed terminal refused replacement until untracked session \(id.rawValue) is retired: \(error)")
                    self.startCompletionPending = false
                    host.publishStartCompletion()
                } else {
                    self.untrackedBrokerSessionID = nil
                    // Retirement is only the prerequisite. The replacement
                    // start owns completion so controllers cannot publish a
                    // transient active state with no broker identity.
                    self.startCompletionPending = false
                    replacement()
                    if !self.startCompletionPending {
                        host.publishStartCompletion()
                    }
                }
            }
        }
    }

    func completeReattachStartIfNeeded(
        _ notifyStartCompletion: Bool,
        host: any BrokerTerminalLifecycleHost
    ) {
        guard notifyStartCompletion, startCompletionPending else { return }
        publishInterruptedExitedOutputRecoveryIfNeeded(host: host)
        startCompletionPending = false
        host.publishStartCompletion()
    }

    private func publishInterruptedExitedOutputRecoveryIfNeeded(host: any BrokerTerminalLifecycleHost) {
        guard notifyStartAfterExitedOutputResolution,
              startFailureDescription == nil,
              host.sessionFailure == nil else { return }
        startFailureDescription = "Exited session recovery was interrupted by teardown; reconnect to resume final output or start a replacement"
        startFailureKind = .failed
    }

    // MARK: - Cancelled launch

    func finishCancelledFreshStart(_ result: Result<BrokerSessionRecord, Error>) {
        let failure: BrokerLaunchFailure
        switch result {
        case .success(let record):
            failure = .registryCommitted(record)
        case .failure(let error):
            failure = BrokerLaunchFailure(error)
        }
        switch failure {
        case .registryCommitted(let record), .outcomeUnknown(let record):
            retireTrackedForTeardown(record.id) { [self] in
                completeCancelledFreshStart()
            }
        case .untracked(let id):
            retireUntrackedForTeardown(id) { [self] in
                completeCancelledFreshStart()
            }
        case .unattributed:
            completeCancelledFreshStart()
        }
    }

    private func completeCancelledFreshStart() {
        freshStartPending = false
        freshStartCancelled = false
        let completions = freshStartTeardownCompletions
        freshStartTeardownCompletions.removeAll()
        completions.forEach { $0() }
        if let restartAfterCancelledFreshStart {
            self.restartAfterCancelledFreshStart = nil
            restartAfterCancelledFreshStart()
        } else {
            startCompletionPending = false
        }
    }

    // MARK: - Retry authority

    private func retireTrackedForTeardown(
        _ id: BrokerSessionID,
        failureCount: Int = 0,
        completion: @escaping @MainActor () -> Void
    ) {
        recovery.markErrored(id) { [self] error in
            DispatchQueue.main.async { [self] in
                guard let error else {
                    completion()
                    return
                }
                let nextFailureCount = failureCount + 1
                let delay = teardownRetryDelay(nextFailureCount)
                NSLog("Broker-backed terminal could not retire tracked session \(id.rawValue) during teardown; retrying in \(delay) seconds: \(error)")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                    retireTrackedForTeardown(id, failureCount: nextFailureCount, completion: completion)
                }
            }
        }
    }

    private func retireUntrackedForTeardown(
        _ id: BrokerSessionID,
        failureCount: Int = 0,
        completion: @escaping @MainActor () -> Void
    ) {
        recovery.retireUntrackedSession(id) { [self] error in
            DispatchQueue.main.async { [self] in
                guard let error else {
                    if untrackedBrokerSessionID == id {
                        untrackedBrokerSessionID = nil
                    }
                    completion()
                    return
                }
                let nextFailureCount = failureCount + 1
                let delay = teardownRetryDelay(nextFailureCount)
                NSLog("Broker-backed terminal could not retire untracked session \(id.rawValue) during teardown; retrying in \(delay) seconds: \(error)")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                    retireUntrackedForTeardown(id, failureCount: nextFailureCount, completion: completion)
                }
            }
        }
    }

    // MARK: - App termination (non-consuming detach)

    func detachPreservingOutput(
        host: any BrokerTerminalLifecycleHost,
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    ) {
        if closeRetirementInFlight {
            closeRetirementCompletions.append(completion)
            return
        }
        if preservingOutputDetachInFlight {
            // A later quit supersedes any reconnect queued after an earlier quit
            // timed out. Both quit transactions still join the same detach owner.
            restartAfterPreservingOutputDetach = nil
            startCompletionPending = false
            preservingOutputDetachCompletions.append(completion)
            return
        }
        preservingOutputDetachInFlight = true
        preservingOutputDetachCompletions = [completion]
        if freshStartPending {
            freshStartCancelled = true
            restartAfterCancelledFreshStart = nil
            freshStartTeardownCompletions.append { [self] in
                completePreservingOutputDetach(.completed)
            }
            return
        }
        // Cancel asynchronous reattach authority before waiting on either output
        // lane. Otherwise a late replay/final-drain callback can acknowledge and
        // retire bytes after Quit has promised to preserve them for relaunch.
        reattachGeneration &+= 1
        startCompletionPending = false
        preservesUnreadOutputForTermination = true
        host.revokeSessionPresentation()
        host.stopOutputPump()
        host.finishOutputLaneWithoutConsuming { [self] in
            DispatchQueue.main.async {
                self.finishPreservingOutputDetach(host: host)
            }
        }
    }

    private func finishPreservingOutputDetach(host: any BrokerTerminalLifecycleHost) {
        if reattachWorkInFlight {
            reattachWorkCompletionWaiters.append { [self] in
                finishPreservingOutputDetach(host: host)
            }
            return
        }
        if exitedOutputResolutionInFlight || runningSessionTeardownProbeInFlight {
            exitedOutputTeardownCompletions.append { [self] outcome in
                continuePreservingOutputDetach(after: outcome, host: host)
            }
            return
        }
        if let brokerSessionID, host.joinClaimedExitResolution(for: brokerSessionID) {
            exitedOutputResolutionInFlight = true
            exitedOutputTeardownCompletions.append { [self] outcome in
                continuePreservingOutputDetach(after: outcome, host: host)
            }
            return
        }
        let cleanupOutcome = currentCleanupOutcome()
        if case .retryableFailure = cleanupOutcome {
            completePreservingOutputDetach(cleanupOutcome)
            return
        }
        if let brokerSessionID {
            recovery.detach(brokerSessionID) { [self] error in
                DispatchQueue.main.async {
                    if let error {
                        NSLog("Broker-backed terminal app-termination detach failed: \(error)")
                        self.completePreservingOutputDetach(
                            .retryableFailure(self.cleanupFailure(from: error))
                        )
                        return
                    }
                    self.completePreservingOutputDetach(.completed)
                }
            }
            return
        }
        if let untrackedBrokerSessionID {
            retireUntrackedForTeardown(untrackedBrokerSessionID) { [self] in
                completePreservingOutputDetach(.completed)
            }
            return
        }
        completePreservingOutputDetach(.completed)
    }

    private func continuePreservingOutputDetach(
        after outcome: TerminalCleanupOutcome,
        host: any BrokerTerminalLifecycleHost
    ) {
        switch outcome {
        case .completed:
            finishPreservingOutputDetach(host: host)
        case .retryableFailure:
            completePreservingOutputDetach(outcome)
        }
    }

    private func completePreservingOutputDetach(_ outcome: TerminalCleanupOutcome) {
        preservesUnreadOutputForTermination = false
        preservingOutputDetachInFlight = false
        let completions = preservingOutputDetachCompletions
        preservingOutputDetachCompletions.removeAll()
        completions.forEach { $0(outcome) }
        let restart = restartAfterPreservingOutputDetach
        restartAfterPreservingOutputDetach = nil
        restart?()
    }

    // MARK: - Tab close

    func retireForClose(
        host: any BrokerTerminalLifecycleHost,
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    ) {
        if closeRetirementInFlight {
            closeRetirementCompletions.append(completion)
            return
        }
        closeRetirementInFlight = true
        closeRetirementCompletions = [completion]
        continueRetireForClose(host: host) { [self] outcome in
            closeRetirementInFlight = false
            let completions = closeRetirementCompletions
            closeRetirementCompletions.removeAll()
            completions.forEach { $0(outcome) }
        }
    }

    private func continueRetireForClose(
        host: any BrokerTerminalLifecycleHost,
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    ) {
        // User close supersedes reconnect intent from a denied/timed-out quit.
        // Join the preserving detach before retiring its now-detached identity.
        restartAfterPreservingOutputDetach = nil
        if preservingOutputDetachInFlight {
            startCompletionPending = false
            preservingOutputDetachCompletions.append { [self] _ in
                continueRetireForClose(host: host, completion: completion)
            }
            return
        }

        // Close is terminal ownership, not a temporary detach. Revoke every
        // activation generation before waiting so a late reattach cannot publish
        // the hidden controller active while retirement is still retryable.
        reattachGeneration &+= 1
        startCompletionPending = false
        host.closeInputWrites()
        if freshStartPending {
            freshStartCancelled = true
            restartAfterCancelledFreshStart = nil
            freshStartTeardownCompletions.append { completion(.completed) }
            return
        }
        host.revokeSessionPresentation()
        // Revoke presentation immediately, but let the serial output operation
        // already in flight classify an observed exit before the close barrier.
        // `finishForClose` stops the lane once that operation returns.
        if let brokerSessionID {
            host.clearOutputAvailabilityHandler(for: brokerSessionID)
        }
        if reattachWorkInFlight {
            reattachWorkCompletionWaiters.append { [self] in
                continueRetireForClose(host: host, completion: completion)
            }
            return
        }
        if exitedOutputResolutionInFlight || runningSessionTeardownProbeInFlight {
            exitedOutputTeardownCompletions.append { [self] outcome in
                finishCloseRetirement(after: outcome, completion: completion)
            }
            return
        }
        host.finishOutputLaneForClose { [self] in
            DispatchQueue.main.async { [self] in
                finishCloseRetirementAfterOutputLane(host: host, completion: completion)
            }
        }
    }

    private func finishCloseRetirementAfterOutputLane(
        host: any BrokerTerminalLifecycleHost,
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    ) {
        if exitedOutputResolutionInFlight || runningSessionTeardownProbeInFlight {
            exitedOutputTeardownCompletions.append { [self] outcome in
                finishCloseRetirement(after: outcome, completion: completion)
            }
            return
        }
        if let brokerSessionID, host.joinClaimedExitResolution(for: brokerSessionID) {
            // The lane classified an exit and claimed the outcome before the
            // main-actor callback published its cleanup owner. Join that claim.
            exitedOutputResolutionInFlight = true
            exitedOutputTeardownCompletions.append { [self] outcome in
                finishCloseRetirement(after: outcome, completion: completion)
            }
            return
        }
        finishCloseRetirement(completion: completion)
    }

    private func finishCloseRetirement(
        after sharedOutcome: TerminalCleanupOutcome,
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    ) {
        guard case .completed = sharedOutcome else {
            completion(sharedOutcome)
            return
        }
        finishCloseRetirement(completion: completion)
    }

    private func finishCloseRetirement(
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    ) {
        if let brokerSessionID {
            recovery.markErrored(brokerSessionID) { [self] error in
                DispatchQueue.main.async { [self] in
                    if let error, !Self.isCompletedRetirementWarning(error) {
                        completion(.retryableFailure(cleanupFailure(from: error)))
                        return
                    }
                    clearIdentity()
                    pendingExitedOutputRetirement = nil
                    completion(.completed)
                }
            }
            return
        }
        if let untrackedBrokerSessionID {
            recovery.retireUntrackedSession(untrackedBrokerSessionID) { [self] error in
                DispatchQueue.main.async { [self] in
                    if let error {
                        completion(.retryableFailure(cleanupFailure(from: error)))
                    } else {
                        self.untrackedBrokerSessionID = nil
                        completion(.completed)
                    }
                }
            }
            return
        }
        completion(.completed)
    }

    // MARK: - Tab teardown / app detach

    func detachForTeardown(
        host: any BrokerTerminalLifecycleHost,
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    ) {
        // A host reattach may still be executing off-main. Invalidate its token
        // before detaching so its late result cannot reopen I/O or publish the
        // owning controller as active after teardown.
        reattachGeneration &+= 1
        host.closeInputWrites()
        if freshStartPending {
            freshStartCancelled = true
            // A later teardown (for example a second quit after the first was
            // denied) supersedes any reconnect queued while cleanup was live.
            // Never launch a replacement after termination authority completes.
            restartAfterCancelledFreshStart = nil
            freshStartTeardownCompletions.append { completion(.completed) }
            return
        }
        if runningSessionTeardownProbeInFlight {
            // The probe remains the sole teardown owner through either exited
            // convergence or completion of the asynchronous running detach.
            // Later teardown requests join it instead of issuing another detach.
            restartAfterRunningSessionTeardown = nil
            startCompletionPending = false
            exitedOutputTeardownCompletions.append(completion)
            return
        }
        if exitedOutputResolutionInFlight {
            // Suppress a delayed activation callback while retaining the final
            // output/cleanup owner until its broker outcome has been published.
            // An already-running restored replay keeps cleanup authority but loses
            // presentation immediately; the teardown-only live-exit probe below is
            // the sole path allowed to render after close begins.
            host.revokeSessionPresentation()
            host.stopOutputPump()
            startCompletionPending = false
            notifyStartAfterExitedOutputResolution = false
            exitedOutputTeardownCompletions.append(completion)
            return
        }
        if let brokerSessionID, host.joinClaimedExitResolution(for: brokerSessionID) {
            // The output lane has observed an exit outcome and queued its main-
            // actor publication. Join that claimed generation instead of racing
            // it with a teardown probe during the queue handoff window.
            host.revokeSessionPresentation()
            host.stopOutputPump()
            startCompletionPending = false
            notifyStartAfterExitedOutputResolution = false
            exitedOutputResolutionInFlight = true
            exitedOutputTeardownCompletions.append(completion)
            return
        }
        startCompletionPending = false
        if let brokerSessionID, !didNotifyTermination, host.canProbeRunningSessionAtTeardown {
            // Quiesce ordinary reads before probing on the same serial lane. A
            // running child remains non-consuming and detaches normally. A child
            // that already stopped is drained, acknowledged, finalized, and
            // retired before teardown releases its cleanup owner. This is required
            // for both signal-driven and production periodic polling.
            //
            // Ordinary run operations use the delivery lease too. Revoke it
            // before the asynchronous probe so a delayed resize/input failure
            // cannot publish after close or quit begins. Exit resolution keeps its
            // independent claim and remains authorized to drain final bytes.
            host.revokeSessionPresentation()
            host.stopOutputPump()
            exitedOutputResolutionInFlight = true
            runningSessionTeardownProbeInFlight = true
            exitedOutputTeardownCompletions.append(completion)
            host.beginRunningSessionTeardownProbe(for: brokerSessionID)
            return
        }
        host.revokeSessionPresentation()
        host.stopOutputPump()
        if let brokerSessionID, !didNotifyTermination {
            if coordinator.requiresOffMainBrokerWork {
                recovery.detach(brokerSessionID) { error in
                    if let error {
                        NSLog("Broker-backed terminal detach failed: \(error)")
                    }
                    DispatchQueue.main.async { [self] in
                        if let error {
                            completion(.retryableFailure(cleanupFailure(from: error)))
                        } else {
                            completion(.completed)
                        }
                    }
                }
                return
            }
            var detachError: Error?
            do {
                _ = try coordinator.detach(brokerSessionID)
            } catch {
                // Detach runs on tab teardown and again during app termination. A
                // broker host outage — or a broker that already dropped the session —
                // must not trap the app while it is quitting. The durable broker
                // record from `ChannelManager.saveState` is what the next launch
                // reads, so report loudly and leave it reattachable for reconcile.
                NSLog("Broker-backed terminal detach failed: \(error)")
                detachError = error
            }
            if let detachError {
                completion(.retryableFailure(cleanupFailure(from: detachError)))
            } else {
                completion(.completed)
            }
            return
        } else if let untrackedBrokerSessionID {
            retireUntrackedForTeardown(untrackedBrokerSessionID) { completion(.completed) }
            return
        }
        completion(.completed)
    }

    func finishRunningSessionTeardownProbe(
        host: any BrokerTerminalLifecycleHost,
        error: Error?
    ) {
        guard exitedOutputResolutionInFlight else { return }
        exitedOutputResolutionInFlight = false
        if let error {
            host.publishSessionFailure(
                TerminalSessionFailure(
                    kind: Self.classifyStartFailure(error),
                    description: String(describing: error)
                )
            )
        }
        host.revokeSessionPresentation()
        host.stopOutputPump()
        guard let brokerSessionID, !didNotifyTermination else {
            finishRunningSessionTeardown(host: host)
            return
        }
        let finish: @Sendable (Error?) -> Void = { error in
            if let error {
                NSLog("Broker-backed terminal detach failed: \(error)")
            }
            DispatchQueue.main.async { [self] in
                finishRunningSessionTeardown(host: host, detachError: error)
            }
        }
        if coordinator.requiresOffMainBrokerWork {
            recovery.detach(brokerSessionID, completion: finish)
        } else {
            do {
                _ = try coordinator.detach(brokerSessionID)
                finish(nil)
            } catch {
                finish(error)
            }
        }
    }

    private func finishRunningSessionTeardown(
        host: any BrokerTerminalLifecycleHost,
        detachError: Error? = nil
    ) {
        let completions = exitedOutputTeardownCompletions
        exitedOutputTeardownCompletions.removeAll()
        runningSessionTeardownProbeInFlight = false
        let outcome = detachError.map { TerminalCleanupOutcome.retryableFailure(cleanupFailure(from: $0)) }
            ?? currentCleanupOutcome()
        completions.forEach { $0(outcome) }
        if let restartAfterRunningSessionTeardown {
            self.restartAfterRunningSessionTeardown = nil
            restartAfterRunningSessionTeardown()
        } else if startCompletionPending {
            startCompletionPending = false
            host.publishStartCompletion()
        }
    }

    func finishExitedOutputResolution(host: any BrokerTerminalLifecycleHost) {
        exitedOutputResolutionInFlight = false
        if runningSessionTeardownProbeInFlight {
            finishRunningSessionTeardown(host: host)
            return
        }
        let completions = exitedOutputTeardownCompletions
        exitedOutputTeardownCompletions.removeAll()
        let outcome = currentCleanupOutcome()
        completions.forEach { $0(outcome) }
        if notifyStartAfterExitedOutputResolution {
            publishInterruptedExitedOutputRecoveryIfNeeded(host: host)
            notifyStartAfterExitedOutputResolution = false
            if startCompletionPending {
                startCompletionPending = false
                host.publishStartCompletion()
            }
        }
    }

    // MARK: - Output-failure recovery

    /// A persistence- or monitoring-broken session cannot keep running. Retire
    /// it and hand its identity to the tab as stale so retry starts a replacement.
    func beginOutputFailureRecovery(
        _ error: Error,
        for sessionID: BrokerSessionID,
        host: any BrokerTerminalLifecycleHost
    ) {
        guard recoveringBrokerSessionID == nil else { return }
        recoveringBrokerSessionID = sessionID
        let originalDescription = String(describing: error)
        recovery.markErrored(sessionID) { [weak self, weak host] recoveryError in
            DispatchQueue.main.async { [weak self, weak host] in
                guard let self, let host,
                      self.recoveringBrokerSessionID == sessionID,
                      self.brokerSessionID == sessionID else { return }
                self.recoveringBrokerSessionID = nil

                if let recoveryError,
                   !Self.isCompletedRetirementWarning(recoveryError) {
                    host.publishSessionFailure(
                        TerminalSessionFailure(
                            kind: .failed,
                            description: originalDescription
                                + "; failed to retire persistence-broken broker session: \(recoveryError)"
                        )
                    )
                    return
                }

                let completedWarningDescription = recoveryError.map {
                    "; broker retirement completed with warning: \($0)"
                } ?? ""
                self.markStale(sessionID)
                host.markSessionIONotReady()
                host.publishSessionFailure(
                    TerminalSessionFailure(
                        kind: .brokerSessionStale,
                        description: originalDescription + completedWarningDescription
                    )
                )
            }
        }
    }

    // MARK: - Failure classification

    nonisolated static func isCompletedExitWarning(_ error: Error) -> Bool {
        if case NativePTYBrokerSessionRuntime.RuntimeError.exitCompletedWithInputCloseFailure = error {
            return true
        }
        if case let BrokerSessionHostClientRuntime.ClientError.hostFailure(code, _) = error {
            return code == "exit-completed-with-input-close-failure"
        }
        if case BrokerSessionHostClientRuntime.ClientError.exitCompletedWithInputCloseFailure = error {
            return true
        }
        return false
    }

    nonisolated static func isCompletedRetirementWarning(_ error: Error) -> Bool {
        if case NativePTYBrokerSessionRuntime.RuntimeError.retirementCompletedWithInputCloseFailure = error {
            return true
        }
        if case NativePTYBrokerSessionRuntime.RuntimeError.retirementCompletedWithOutputFailure = error {
            return true
        }
        if case let BrokerSessionHostClientRuntime.ClientError.hostFailure(code, _) = error {
            return code == "retirement-completed-with-input-close-failure"
                || code == "retirement-completed-with-output-failure"
        }
        return false
    }

    nonisolated static func isCompletedOutputRetirementWarning(_ error: Error) -> Bool {
        if case NativePTYBrokerSessionRuntime.RuntimeError.retirementCompletedWithOutputFailure = error {
            return true
        }
        if case let BrokerSessionHostClientRuntime.ClientError.hostFailure(code, _) = error {
            return code == "retirement-completed-with-output-failure"
        }
        return false
    }

    nonisolated static func isScrollbackPersistenceFailure(_ error: Error) -> Bool {
        if let runtimeError = error as? NativePTYBrokerSessionRuntime.RuntimeError,
           case .scrollbackPersistenceFailed = runtimeError {
            return true
        }
        if case let BrokerSessionHostClientRuntime.ClientError.hostFailure(code, _) = error {
            return code == "scrollback-persistence-failed"
        }
        return false
    }

    nonisolated static func isOutputMonitoringFailure(_ error: Error) -> Bool {
        if let runtimeError = error as? NativePTYBrokerSessionRuntime.RuntimeError,
           case .outputMonitoringFailed = runtimeError {
            return true
        }
        if case let BrokerSessionHostClientRuntime.ClientError.hostFailure(code, _) = error {
            return code == "output-monitoring-failed"
        }
        return false
    }

    nonisolated static func classifyStartFailure(_ error: Error) -> TerminalStartFailureKind {
        if isCompletedRetirementWarning(error) {
            return .brokerSessionStale
        }
        if let coordinatorError = error as? BrokerSessionCoordinator.CoordinatorError {
            switch coordinatorError {
            case .missingSession, .staleSession:
                return .brokerSessionStale
            case .brokerHostUnavailable:
                return .brokerHostUnavailable
            case .launchOutcomeUnknown:
                return .brokerHostUnavailable
            case .launchStillPending:
                return .failed
            case .retirementRollbackFailed, .retirementFinalizationFailed,
                 .detachRollbackFailed, .reattachRollbackFailed,
                 .reattachCleanupFailed, .exitRollbackFailed, .exitFinalizationFailed,
                 .exitCodeMismatch, .exitStillPending:
                return .failed
            case .concurrentSessionTransition, .untrackedSession,
                 .agentStatusOwnerTokenMismatch:
                return .failed
            case .registryTransitionCommitted, .registryPruneCommitted:
                return .failed
            }
        }
        if case BrokerSessionHostClientRuntime.ClientError.transportFailed = error {
            return .brokerHostUnavailable
        }
        if case BrokerSessionHostClientRuntime.ClientError.outputTransportFailed = error {
            return .brokerHostUnavailable
        }
        if let runtimeError = error as? NativePTYBrokerSessionRuntime.RuntimeError,
           case .missingSession = runtimeError {
            return .brokerSessionStale
        }
        if let runtimeError = error as? NativePTYBrokerSessionRuntime.RuntimeError,
           case .scrollbackPersistenceFailed = runtimeError {
            return .brokerSessionStale
        }
        if let runtimeError = error as? NativePTYBrokerSessionRuntime.RuntimeError,
           case .outputMonitoringFailed = runtimeError {
            return .brokerSessionStale
        }
        if case let BrokerSessionHostClientRuntime.ClientError.hostFailure(code, message) = error,
           code == "scrollback-persistence-failed"
               || code == "output-monitoring-failed"
               || (code == "missing-session" && message.contains("missingSession")) {
            return .brokerSessionStale
        }
        return .failed
    }
}
