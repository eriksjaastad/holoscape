import AppKit
import SwiftTerm

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

/// TerminalProcess implementation backed by Holoscape's broker runtime instead
/// of SwiftTerm's LocalProcessTerminalView owning the child process directly.
///
/// This is the opt-in bridge for #7168: SwiftTerm remains the renderer, while
/// process input/output/resize flow through BrokerSessionCoordinator and the
/// native PTY runtime behind it.
@MainActor
final class BrokerBackedTerminalProcess: TerminalProcess {
    enum TerminalError: Error, Equatable {
        case startFailed(String)
        case sessionNotStarted
    }

    private let channelID: UUID
    private let channelType: ChannelType
    private let label: String?
    private let environmentProfile: BrokerEnvironmentProfile
    private let coordinator: any BrokerSessionCoordinating
    private let inputCoordinator: BrokerInputCoordinator
    private let outputCoordinator: BrokerOutputCoordinator
    private let failureRecoveryCoordinator: BrokerFailureRecoveryCoordinator
    private let teardownRetryDelay: (Int) -> TimeInterval
    private let outputDeliveryTimeout: TimeInterval
    private let terminalView: HoloscapeTerminalView
    private var outputHandler: (() -> Void)?
    private var sessionFailureHandler: ((TerminalSessionFailure) -> Void)?
    private var userInputHandler: ((ArraySlice<UInt8>) -> Void)?
    private var hostCurrentDirectoryHandler: ((String?) -> Void)?
    private var terminationHandler: ((Int32?) -> Void)?
    private var startCompletionHandler: (() -> Void)?
    private var startCompletionPending = false
    /// A restored identity is not safe for I/O until reattach and scrollback
    /// replay commit. Keeping this separate from `brokerSessionID` prevents an
    /// installed output handler from draining live bytes ahead of replay.
    private var sessionIOReady = false
    private var freshStartPending = false
    private var freshStartCancelled = false
    private var freshStartTeardownCompletions: [@MainActor () -> Void] = []
    /// A denied quit may reopen channel interaction while cancellation cleanup
    /// still owns an in-flight launch. Preserve the reconnect instead of leaving
    /// its controller waiting forever on the cancelled generation.
    private var restartAfterCancelledFreshStart: (@MainActor () -> Void)?
    private var reattachGeneration: UInt = 0
    private var reattachWorkInFlight = false
    private var reattachWorkCompletionWaiters: [@MainActor () -> Void] = []
    /// App termination preserves unread broker output instead of allowing an
    /// in-flight restored-session drain to acknowledge and retire it unseen.
    private var preservesUnreadOutputForTermination = false
    private var preservingOutputDetachInFlight = false
    private var preservingOutputDetachCompletions: [@MainActor () -> Void] = []
    private var restartAfterPreservingOutputDetach: (@MainActor () -> Void)?
    /// Identifies the terminal-view ownership window allowed to consume broker
    /// output. A queued main-actor delivery must still hold this exact lease;
    /// matching the broker ID alone is insufficient because teardown deliberately
    /// preserves that ID for later reattach.
    private var nextOutputDeliveryGeneration: UInt = 0
    private var activeOutputDeliveryGeneration: UInt?
    private var activeOutputHandoffGeneration: UInt?
    private let outputDeliveryGate = BrokerOutputDeliveryGate()
    private let outputReadLane = BrokerOutputReadLane()
    private let inputWriteLane = BrokerInputWriteLane()
    private let exitedOutputResolutionClaim = BrokerExitResolutionClaim()
    private(set) var brokerSessionID: BrokerSessionID?
    private(set) var agentStatusOwnerToken: String?
    /// Identity of the broker session this terminal failed to reattach because
    /// the broker no longer owns it. Kept separate from `brokerSessionID` so a
    /// retry spawns the replacement the stale guidance promises instead of
    /// reattaching the dead session, while the owning tab can still persist the
    /// dead identity for the next launch.
    private(set) var staleBrokerSessionID: BrokerSessionID?
    private var recoveringBrokerSessionID: BrokerSessionID?
    private var didNotifyTermination = false
    /// Most recent failure observed while operating the live session. `nil` means
    /// the session is healthy (or has not started yet).
    private(set) var sessionFailure: TerminalSessionFailure?
    private(set) var startFailureDescription: String?
    private(set) var startFailureKind: TerminalStartFailureKind?
    private(set) var untrackedBrokerSessionID: BrokerSessionID?
    private(set) var lastScrollbackReplay: ScrollbackReplay?
    /// The broker generation already represented by this terminal view.
    private var presentedBrokerSessionID: BrokerSessionID?
    /// Bytes rendered before their broker acknowledgement failed. A retry strips
    /// this exact prefix from the next transactional snapshot, acknowledges the
    /// full generation, and renders only genuinely new suffix bytes.
    private var presentedUnacknowledgedOutput: (sessionID: BrokerSessionID, data: Data)?
    /// Cleanup authority survives presentation-lease revocation. A retry resumes
    /// retirement instead of rendering unacknowledged final bytes again.
    private(set) var pendingExitedOutputRetirement: BrokerExitedOutputRetirement?
    private var exitedOutputRetirementInFlight = false
    /// Covers the final read, acknowledgement, and any resulting retirement.
    /// Teardown waits for this authority to resolve instead of revoking the
    /// presentation lease and allowing the outcome to disappear with the tab.
    private var exitedOutputResolutionInFlight = false
    private var exitedOutputTeardownCompletions: [@MainActor (TerminalCleanupOutcome) -> Void] = []
    private var runningSessionTeardownProbeInFlight = false
    private var restartAfterRunningSessionTeardown: (@MainActor () -> Void)?
    /// A denied quit can re-enable reconnect while exited-output cleanup still
    /// owns the old generation. Keep that activation pending until cleanup
    /// publishes its result rather than reporting the cleanup-only runtime active.
    private var notifyStartAfterExitedOutputResolution = false
    private lazy var terminalViewDelegate = BrokerBackedTerminalViewDelegate(owner: self)

    var terminalContentView: NSView { terminalView }
    var currentGridSize: TerminalGridSize { terminalView.currentGridSize }
    var brokerOwnedSessionID: BrokerSessionID? { brokerSessionID }
    var completesStartAsynchronously: Bool { startCompletionPending }

    init(
        channelID: UUID,
        channelType: ChannelType,
        label: String?,
        environmentProfile: BrokerEnvironmentProfile,
        existingBrokerSessionID: BrokerSessionID? = nil,
        pendingExitedOutputRetirement: BrokerExitedOutputRetirement? = nil,
        coordinator: any BrokerSessionCoordinating = BrokerSessionCoordinator(
            runtime: NativePTYBrokerSessionRuntime(scrollbackDirectory: ScrollbackPersistencePolicy.defaultDiskDirectory)
        ),
        terminalView: HoloscapeTerminalView = HoloscapeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600)),
        teardownRetryDelay: @escaping (Int) -> TimeInterval = BrokerTeardownRetryPolicy.delay(afterFailureCount:),
        outputDeliveryTimeout: TimeInterval = 5.0
    ) {
        self.channelID = channelID
        self.channelType = channelType
        self.label = label
        self.environmentProfile = environmentProfile
        self.coordinator = coordinator
        self.inputCoordinator = BrokerInputCoordinator(coordinator)
        self.outputCoordinator = BrokerOutputCoordinator(coordinator)
        self.failureRecoveryCoordinator = BrokerFailureRecoveryCoordinator(coordinator)
        self.teardownRetryDelay = teardownRetryDelay
        self.outputDeliveryTimeout = outputDeliveryTimeout
        self.terminalView = terminalView
        self.brokerSessionID = existingBrokerSessionID
        self.pendingExitedOutputRetirement = pendingExitedOutputRetirement

        terminalView.setUserInputHandler { [weak self] data in
            guard let self else { return }
            self.userInputHandler?(data)
            self.send(Array(data))
        }
        terminalView.processDelegate = terminalViewDelegate
    }

    func startProcess(
        executable: String,
        args: [String],
        environment: [String]?,
        execName: String?,
        currentDirectory: String?
    ) {
        if preservingOutputDetachInFlight {
            startCompletionPending = true
            restartAfterPreservingOutputDetach = { [weak self] in
                guard let self else { return }
                self.startCompletionPending = false
                self.startProcess(
                    executable: executable,
                    args: args,
                    environment: environment,
                    execName: execName,
                    currentDirectory: currentDirectory
                )
                if !self.startCompletionPending {
                    self.startCompletionHandler?()
                }
            }
            return
        }
        if freshStartPending, freshStartCancelled {
            restartAfterCancelledFreshStart = { [weak self] in
                guard let self else { return }
                self.startCompletionPending = false
                self.continueStartProcess(
                    executable: executable,
                    args: args,
                    environment: environment,
                    currentDirectory: currentDirectory
                )
                if !self.startCompletionPending {
                    self.startCompletionHandler?()
                }
            }
            return
        }
        if runningSessionTeardownProbeInFlight {
            startCompletionPending = true
            restartAfterRunningSessionTeardown = { [weak self] in
                guard let self else { return }
                self.startCompletionPending = false
                // Re-enter the complete start gate after teardown. The probe may
                // have discovered an exited session and published retryable
                // retirement authority while this reconnect was queued.
                self.startProcess(
                    executable: executable,
                    args: args,
                    environment: environment,
                    execName: execName,
                    currentDirectory: currentDirectory
                )
                if !self.startCompletionPending {
                    self.startCompletionHandler?()
                }
            }
            return
        }
        if exitedOutputResolutionInFlight || exitedOutputRetirementInFlight {
            startCompletionPending = true
            notifyStartAfterExitedOutputResolution = true
            return
        }
        guard recoveringBrokerSessionID == nil, !startCompletionPending,
              !exitedOutputRetirementInFlight else {
            NSLog("Broker-backed terminal retry ignored while session recovery is still running")
            return
        }
        if let pendingExitedOutputRetirement {
            retryExitedOutputRetirement(pendingExitedOutputRetirement)
            return
        }
        if let untrackedBrokerSessionID {
            // This generation is outside the durable registry, so replacement
            // cannot begin until retirement is confirmed. Always perform that
            // potentially blocking cleanup off-main, including for in-process
            // runtimes and test doubles that do not otherwise require host work.
            startCompletionPending = true
            failureRecoveryCoordinator.retireUntrackedSession(untrackedBrokerSessionID) { [weak self] error in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.startCompletionPending,
                          self.untrackedBrokerSessionID == untrackedBrokerSessionID else { return }
                    if let error {
                        self.startFailureDescription = String(describing: error)
                        self.startFailureKind = .failed
                        NSLog("Broker-backed terminal refused replacement until untracked session \(untrackedBrokerSessionID.rawValue) is retired: \(error)")
                        self.startCompletionPending = false
                        self.startCompletionHandler?()
                    } else {
                        self.untrackedBrokerSessionID = nil
                        // Retirement is only the prerequisite. The replacement
                        // start owns completion so controllers cannot publish a
                        // transient active state with no broker identity.
                        self.startCompletionPending = false
                        self.continueStartProcess(
                            executable: executable,
                            args: args,
                            environment: environment,
                            currentDirectory: currentDirectory
                        )
                        if !self.startCompletionPending {
                            self.startCompletionHandler?()
                        }
                    }
                }
            }
            return
        }
        continueStartProcess(
            executable: executable,
            args: args,
            environment: environment,
            currentDirectory: currentDirectory
        )
    }

    func resumeBrokerSessionForCleanup() {
        guard recoveringBrokerSessionID == nil, !startCompletionPending,
              !exitedOutputRetirementInFlight else {
            NSLog("Broker-backed terminal cleanup resume ignored while session recovery is still running")
            return
        }
        if let pendingExitedOutputRetirement {
            retryExitedOutputRetirement(pendingExitedOutputRetirement)
            return
        }
        guard let brokerSessionID else { return }
        inputWriteLane.close()
        startFailureDescription = nil
        startFailureKind = nil
        lastScrollbackReplay = nil
        staleBrokerSessionID = nil
        sessionFailure = nil
        revokeOutputDeliveryOwnership()
        sessionIOReady = false
        reattachExistingSession(
            brokerSessionID,
            shouldReplayScrollback: false,
            cleanupOnly: true
        )
    }

    private func continueStartProcess(
        executable: String,
        args: [String],
        environment: [String]?,
        currentDirectory: String?
    ) {
        inputWriteLane.close()
        startFailureDescription = nil
        startFailureKind = nil
        untrackedBrokerSessionID = nil
        lastScrollbackReplay = nil
        staleBrokerSessionID = nil
        sessionFailure = nil
        revokeOutputDeliveryOwnership()
        sessionIOReady = false
        if let existingBrokerSessionID = brokerSessionID {
            reattachExistingSession(existingBrokerSessionID)
            return
        }

        let ownerToken = Self.agentStatusOwnerToken(
            from: environment,
            channelType: channelType
        )
        let request = BrokerSessionLaunchRequest(
            command: executable,
            arguments: args,
            workingDirectory: currentDirectory,
            environmentProfile: environmentProfile,
            agentStatusOwnerToken: ownerToken,
            initialSize: currentGridSize
        )

        if coordinator.requiresOffMainBrokerWork {
            startCompletionPending = true
            freshStartPending = true
            freshStartCancelled = false
            failureRecoveryCoordinator.start(
                request,
                channelType: channelType,
                label: label,
                attachedChannelID: channelID
            ) { [self] result in
                DispatchQueue.main.async { [self] in
                    guard freshStartPending else { return }
                    if freshStartCancelled {
                        finishCancelledFreshStart(result)
                        return
                    }
                    finishNewSessionStart(result)
                    freshStartPending = false
                    startCompletionPending = false
                    startCompletionHandler?()
                }
            }
            return
        }

        finishNewSessionStart(Result {
            try coordinator.start(
                request,
                channelType: channelType,
                label: label,
                attachedChannelID: channelID
            )
        })
    }

    private func finishNewSessionStart(_ result: Result<BrokerSessionRecord, Error>) {
        do {
            let record = try result.get()
            brokerSessionID = record.id
            presentedBrokerSessionID = record.id
            agentStatusOwnerToken = record.agentStatusOwnerToken
            didNotifyTermination = false
            inputWriteLane.open(for: record.id)
            beginOutputDeliveryOwnership()
            sessionIOReady = true
            if outputHandler != nil {
                startOutputPump()
            }
        } catch {
            if case let BrokerSessionCoordinator.CoordinatorError.untrackedSession(id, _, _) = error {
                untrackedBrokerSessionID = id
            }
            brokerSessionID = nil
            agentStatusOwnerToken = nil
            revokeOutputDeliveryOwnership()
            sessionIOReady = false
            startFailureDescription = String(describing: error)
            startFailureKind = classifyStartFailure(error)
            NSLog("Broker-backed terminal start failed: \(error)")
        }
    }

    private func finishCancelledFreshStart(_ result: Result<BrokerSessionRecord, Error>) {
        switch result {
        case .success(let record):
            retireTrackedForTeardown(record.id) { [self] in
                completeCancelledFreshStart()
            }
        case .failure(let error):
            if case let BrokerSessionCoordinator.CoordinatorError.untrackedSession(id, _, _) = error {
                retireUntrackedForTeardown(id) { [self] in
                    completeCancelledFreshStart()
                }
            } else {
                completeCancelledFreshStart()
            }
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

    private func retireTrackedForTeardown(
        _ id: BrokerSessionID,
        failureCount: Int = 0,
        completion: @escaping @MainActor () -> Void
    ) {
        failureRecoveryCoordinator.markErrored(id) { [self] error in
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
        failureRecoveryCoordinator.retireUntrackedSession(id) { [self] error in
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

    static func agentStatusOwnerToken(
        from environment: [String]?,
        channelType: ChannelType
    ) -> String? {
        guard channelType == .agentDirect || channelType == .agentAPI else { return nil }
        let prefix = "HOLOSCAPE_AGENT_STATUS_OWNER_TOKEN="
        return environment?
            .first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    func updateWorkingDirectory(_ directory: String) throws {
        guard let brokerSessionID else { throw TerminalError.sessionNotStarted }
        _ = try coordinator.updateWorkingDirectory(brokerSessionID, to: directory)
    }

    private func reattachExistingSession(
        _ sessionID: BrokerSessionID,
        shouldReplayScrollback explicitReplayPolicy: Bool? = nil,
        cleanupOnly: Bool = false
    ) {
        startFailureDescription = nil
        startFailureKind = nil
        lastScrollbackReplay = nil
        staleBrokerSessionID = nil
        sessionFailure = nil
        let coordinator = self.coordinator
        let channelID = self.channelID
        let shouldReplayScrollback = explicitReplayPolicy ?? (presentedBrokerSessionID != sessionID)
        reattachGeneration &+= 1
        let generation = reattachGeneration
        guard coordinator.requiresOffMainBrokerWork else {
            finishReattach(
                sessionID: sessionID,
                result: Result { try coordinator.reattach(sessionID, attachedChannelID: channelID) },
                replay: nil,
                shouldReplayScrollback: shouldReplayScrollback,
                notifyStartCompletion: false,
                authorityGeneration: generation,
                cleanupOnly: cleanupOnly
            )
            return
        }
        startCompletionPending = true
        reattachWorkInFlight = true
        failureRecoveryCoordinator.reattach(
            sessionID,
            attachedChannelID: channelID,
            shouldReplayScrollback: shouldReplayScrollback
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.reattachWorkInFlight = false
                let waiters = self.reattachWorkCompletionWaiters
                self.reattachWorkCompletionWaiters.removeAll()
                waiters.forEach { $0() }
                guard self.startCompletionPending,
                      self.reattachGeneration == generation,
                      self.brokerSessionID == sessionID else { return }
                self.finishReattach(
                    sessionID: sessionID,
                    result: result.record,
                    replay: result.replay,
                    shouldReplayScrollback: shouldReplayScrollback,
                    notifyStartCompletion: true,
                    authorityGeneration: generation,
                    cleanupOnly: cleanupOnly
                )
            }
        }
    }

    private func finishReattach(
        sessionID: BrokerSessionID,
        result: Result<BrokerSessionRecord, Error>,
        replay: ScrollbackReplayResult?,
        shouldReplayScrollback: Bool,
        notifyStartCompletion: Bool,
        authorityGeneration: UInt,
        cleanupOnly: Bool
    ) {
        do {
            let record = try result.get()
            brokerSessionID = record.id
            agentStatusOwnerToken = record.agentStatusOwnerToken
            didNotifyTermination = false
            // The durable broker record is authoritative after a delayed retry;
            // publish it through the same host-truth seam as OSC 7 so the owning
            // shell replaces any stale channel metadata before saving again.
            hostCurrentDirectoryHandler?(record.workingDirectory)
            if cleanupOnly, record.lifecycle == .exited {
                guard let exitCode = record.exitCode else {
                    startFailureDescription = "Exited broker session \(record.id.rawValue) has no exit code"
                    startFailureKind = .failed
                    completeReattachStartIfNeeded(notifyStartCompletion)
                    return
                }
                exitedOutputResolutionInFlight = true
                retireExitedSession(
                    record,
                    exitCode: exitCode,
                    deliveryGeneration: 0,
                    notifyStartCompletion: notifyStartCompletion
                )
                return
            }
            if shouldReplayScrollback {
                if let replay {
                    applyScrollbackReplay(replay, for: record.id)
                } else {
                    restoreScrollbackReplay(for: record.id)
                }
                // Presentation and broker acknowledgement are separate facts.
                // Once this terminal view renders a replay (or its recovery
                // warning), teardown must not let a same-object retry render it
                // again merely because the asynchronous acknowledgement callback
                // lost authority before it completed.
                presentedBrokerSessionID = record.id
            }
            if let generation = replay?.generation {
                if record.lifecycle == .exited {
                    exitedOutputResolutionInFlight = true
                }
                failureRecoveryCoordinator.acknowledgeOutput(record.id, through: generation) { [self] error in
                    DispatchQueue.main.async {
                        guard self.brokerSessionID == record.id else { return }
                        if record.lifecycle != .exited {
                            guard self.reattachGeneration == authorityGeneration,
                                  self.startCompletionPending else { return }
                        }
                        if let error {
                            if record.lifecycle == .exited {
                                self.retireExitedSessionAfterOutputFailure(
                                    record.id,
                                    error: error,
                                    observedExitCode: record.exitCode,
                                    notifyStartCompletion: notifyStartCompletion
                                )
                            } else {
                                self.failReattach(error, sessionID: sessionID)
                                self.completeReattachStartIfNeeded(notifyStartCompletion)
                            }
                            return
                        }
                        guard self.reattachGeneration == authorityGeneration,
                              self.startCompletionPending else {
                            if let exitCode = record.exitCode {
                                self.retireExitedSession(
                                    record,
                                    exitCode: exitCode,
                                    deliveryGeneration: self.activeOutputDeliveryGeneration ?? 0,
                                    notifyStartCompletion: false
                                )
                            } else {
                                self.finishExitedOutputResolution()
                            }
                            return
                        }
                        self.completeSuccessfulReattach(record, notifyStartCompletion: notifyStartCompletion)
                    }
                }
                return
            }
            completeSuccessfulReattach(record, notifyStartCompletion: notifyStartCompletion)
        } catch {
            failReattach(error, sessionID: sessionID)
            completeReattachStartIfNeeded(notifyStartCompletion)
        }
    }

    private func completeSuccessfulReattach(
        _ record: BrokerSessionRecord,
        notifyStartCompletion: Bool
    ) {
        inputWriteLane.open(for: record.id)
        presentedBrokerSessionID = record.id
        if record.lifecycle == .exited {
            beginOutputDeliveryOwnership()
            sessionIOReady = false
            inputWriteLane.close()
            finishExitedReattach(record, notifyStartCompletion: notifyStartCompletion)
            return
        }
        if record.lifecycle == .exiting {
            beginOutputDeliveryOwnership()
            // Final output is still readable, but the durable exit intent must
            // never reopen input writes to a process that may already be gone.
            sessionIOReady = true
            inputWriteLane.close()
            if outputHandler != nil {
                startOutputPump()
            }
            completeReattachStartIfNeeded(notifyStartCompletion)
            return
        }
        beginOutputDeliveryOwnership()
        sessionIOReady = true
        if outputHandler != nil {
            startOutputPump()
        }
        completeReattachStartIfNeeded(notifyStartCompletion)
    }

    private func failReattach(_ error: Error, sessionID: BrokerSessionID) {
        startFailureDescription = String(describing: error)
        startFailureKind = classifyStartFailure(error)
        switch startFailureKind {
        case .brokerHostUnavailable:
            brokerSessionID = sessionID
        case .brokerSessionStale:
            brokerSessionID = nil
            staleBrokerSessionID = sessionID
        case .failed, .none:
            brokerSessionID = sessionID
        }
        agentStatusOwnerToken = nil
        revokeOutputDeliveryOwnership()
        sessionIOReady = false
        NSLog("Broker-backed terminal reattach failed: \(error)")
    }

    private func finishExitedReattach(
        _ record: BrokerSessionRecord,
        notifyStartCompletion: Bool
    ) {
        guard let exitCode = record.exitCode else {
            startFailureDescription = "Exited broker session \(record.id.rawValue) has no exit code"
            startFailureKind = .failed
            completeReattachStartIfNeeded(notifyStartCompletion)
            return
        }
        guard let deliveryGeneration = activeOutputDeliveryGeneration else {
            completeReattachStartIfNeeded(notifyStartCompletion)
            return
        }
        exitedOutputResolutionInFlight = true

        drainExitedOutput(
            record,
            exitCode: exitCode,
            deliveryGeneration: deliveryGeneration,
            notifyStartCompletion: notifyStartCompletion
        )
    }

    private func drainExitedOutput(
        _ record: BrokerSessionRecord,
        exitCode: Int32,
        deliveryGeneration: UInt,
        notifyStartCompletion: Bool
    ) {
        let consume: @MainActor @Sendable (Result<BrokerOutputSnapshot, Error>) -> Void = { [self] result in
            guard self.brokerSessionID == record.id else { return }
            do {
                let snapshot = try result.get()
                // Successful output belongs to the presentation lease and must
                // not be rendered after teardown. A failed read, however, owns
                // completed-session retirement independently of that lease.
                guard self.activeOutputDeliveryGeneration == deliveryGeneration else {
                    if self.preservesUnreadOutputForTermination {
                        // Quit owns a non-consuming detach. The snapshot remains
                        // broker-owned and unacknowledged for replay next launch.
                        self.finishExitedOutputResolution()
                        return
                    }
                    if let generation = snapshot.generation {
                        self.startCompletionPending = true
                        self.failureRecoveryCoordinator.acknowledgeOutput(record.id, through: generation) { error in
                            DispatchQueue.main.async {
                                guard self.brokerSessionID == record.id else { return }
                                if let error {
                                    self.retireExitedSessionAfterOutputFailure(
                                        record.id,
                                        error: error,
                                        observedExitCode: exitCode,
                                        notifyStartCompletion: false
                                    )
                                } else {
                                    self.retireExitedSession(
                                        record,
                                        exitCode: exitCode,
                                        deliveryGeneration: deliveryGeneration,
                                        notifyStartCompletion: false
                                    )
                                }
                            }
                        }
                    } else {
                        self.retireExitedSession(
                            record,
                            exitCode: exitCode,
                            deliveryGeneration: deliveryGeneration,
                            notifyStartCompletion: false
                        )
                    }
                    return
                }
                self.handleOutputPumpSample(snapshot.data, for: record.id)
                if let generation = snapshot.generation {
                    // A nominally synchronous coordinator still acknowledges on
                    // the recovery worker. Delay controller activation until the
                    // acknowledgement and any required retirement are complete.
                    let acknowledgementNotifiesStart = notifyStartCompletion || !self.startCompletionPending
                    self.startCompletionPending = true
                    self.failureRecoveryCoordinator.acknowledgeOutput(record.id, through: generation) { error in
                        DispatchQueue.main.async {
                            guard self.brokerSessionID == record.id else { return }
                            if let error {
                                self.retireExitedSessionAfterOutputFailure(
                                    record.id,
                                    error: error,
                                    observedExitCode: exitCode,
                                    notifyStartCompletion: acknowledgementNotifiesStart
                                )
                                return
                            }
                            guard self.activeOutputDeliveryGeneration == deliveryGeneration else {
                                self.retireExitedSession(
                                    record,
                                    exitCode: exitCode,
                                    deliveryGeneration: deliveryGeneration,
                                    notifyStartCompletion: false
                                )
                                return
                            }
                            self.drainExitedOutput(
                                record,
                                exitCode: exitCode,
                                deliveryGeneration: deliveryGeneration,
                                notifyStartCompletion: acknowledgementNotifiesStart
                            )
                        }
                    }
                } else {
                    self.retireExitedSession(
                        record,
                        exitCode: exitCode,
                        deliveryGeneration: deliveryGeneration,
                        notifyStartCompletion: notifyStartCompletion
                    )
                }
            } catch {
                self.retireExitedSessionAfterOutputFailure(
                    record.id,
                    error: error,
                    observedExitCode: exitCode,
                    notifyStartCompletion: notifyStartCompletion
                )
            }
        }

        if coordinator.requiresOffMainBrokerWork {
            failureRecoveryCoordinator.readAvailableOutput(record.id) { result in
                DispatchQueue.main.async {
                    consume(result)
                }
            }
        } else {
            consume(Result {
                try coordinator.snapshotAvailableOutput(record.id)
            })
        }
    }

    private func retireExitedSession(
        _ record: BrokerSessionRecord,
        exitCode: Int32,
        deliveryGeneration: UInt,
        notifyStartCompletion: Bool
    ) {
        let retirementNotifiesStart = notifyStartCompletion || !startCompletionPending
        startCompletionPending = true
        let mismatchDescription: String? = {
            guard let requestedExitCode = record.requestedExitCode,
                  requestedExitCode != exitCode else { return nil }
            return String(
                describing: BrokerSessionCoordinator.CoordinatorError.exitCodeMismatch(
                    record.id,
                    expected: requestedExitCode,
                    observed: exitCode
                )
            )
        }()
        let completion: @Sendable (Error?) -> Void = { [self] error in
            DispatchQueue.main.async {
                guard self.brokerSessionID == record.id else { return }
                let presentationLeaseIsActive = self.activeOutputDeliveryGeneration == deliveryGeneration
                let completionWarning = error.flatMap { self.isCompletedRetirementWarning($0) ? $0 : nil }
                if let error, completionWarning == nil {
                    if let mismatchDescription {
                        let combined = BrokerSessionCompositeFailure(
                            description: "\(mismatchDescription); failed to retire completed broker session: \(error)"
                        )
                        self.retainExitedOutputRetirement(
                            sessionID: record.id,
                            failureDescription: combined.description,
                            failureKind: .failed,
                            observedExitCode: exitCode
                        )
                        self.publishSessionFailure(
                            TerminalSessionFailure(kind: .failed, description: combined.description)
                        )
                        self.failExitedOutputDelivery(combined, notifyStartCompletion: retirementNotifiesStart)
                    } else {
                        self.retainExitedOutputRetirement(
                            sessionID: record.id,
                            failureDescription: String(describing: error),
                            failureKind: self.classifyStartFailure(error),
                            observedExitCode: exitCode
                        )
                        self.failExitedOutputDelivery(error, notifyStartCompletion: retirementNotifiesStart)
                    }
                    self.finishExitedOutputResolution()
                    return
                }
                self.revokeOutputDeliveryOwnership()
                self.brokerSessionID = nil
                self.agentStatusOwnerToken = nil
                self.completeReattachStartIfNeeded(retirementNotifiesStart)
                if let mismatchDescription, let completionWarning {
                    self.publishSessionFailure(
                        TerminalSessionFailure(
                            kind: .failed,
                            description: "\(mismatchDescription); broker retirement completed with warning: \(completionWarning)"
                        )
                    )
                } else if let mismatchDescription {
                    self.publishSessionFailure(
                        TerminalSessionFailure(kind: .failed, description: mismatchDescription)
                    )
                } else if let completionWarning {
                    self.publishSessionFailure(
                        TerminalSessionFailure(
                            kind: .failed,
                            description: String(describing: completionWarning)
                        )
                    )
                }
                let publishTermination: @MainActor @Sendable () -> Void = { [weak self] in
                    guard let self, !self.didNotifyTermination else { return }
                    self.didNotifyTermination = true
                    self.terminationHandler?(exitCode)
                }
                if !presentationLeaseIsActive {
                    // Teardown revoked presentation, not lifecycle truth. Publish
                    // the cleared broker identity before releasing the quit
                    // barrier so the controller cannot persist a retired ID.
                    publishTermination()
                    self.finishExitedOutputResolution()
                } else if retirementNotifiesStart {
                    publishTermination()
                    self.finishExitedOutputResolution()
                } else {
                    // Synchronous controller activation calls finishActivation
                    // after startProcess returns. Publish exit on the next main
                    // turn so that final state cannot be overwritten as active.
                    DispatchQueue.main.async {
                        publishTermination()
                        self.finishExitedOutputResolution()
                    }
                }
            }
        }

        if coordinator.requiresOffMainBrokerWork {
            failureRecoveryCoordinator.retireCompletedSession(record.id, completion: completion)
            return
        }
        do {
            try coordinator.retireCompletedSession(record.id)
            completion(nil)
        } catch {
            completion(error)
        }
    }

    private func failExitedOutputDelivery(_ error: Error, notifyStartCompletion: Bool) {
        revokeOutputDeliveryOwnership()
        startFailureDescription = String(describing: error)
        startFailureKind = classifyStartFailure(error)
        completeReattachStartIfNeeded(notifyStartCompletion)
    }

    private func retainExitedOutputRetirement(
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

    private func retireExitedSessionAfterOutputFailure(
        _ id: BrokerSessionID,
        error outputError: Error,
        observedExitCode: Int32? = nil,
        notifyStartCompletion: Bool
    ) {
        let pending = BrokerExitedOutputRetirement(
            sessionID: id,
            outputFailureDescription: String(describing: outputError),
            outputFailureKind: classifyStartFailure(outputError),
            observedExitCode: observedExitCode
        )
        pendingExitedOutputRetirement = pending
        exitedOutputRetirementInFlight = true

        if coordinator.requiresOffMainBrokerWork {
            failureRecoveryCoordinator.retireCompletedSession(id) { [self] retirementError in
                DispatchQueue.main.async {
                    self.finishExitedOutputRetirement(
                        pending,
                        retirementError: retirementError,
                        notifyStartCompletion: notifyStartCompletion
                    )
                }
            }
            return
        }
        do {
            try coordinator.retireCompletedSession(id)
            finishExitedOutputRetirement(
                pending,
                retirementError: nil,
                notifyStartCompletion: notifyStartCompletion
            )
        } catch {
            finishExitedOutputRetirement(
                pending,
                retirementError: error,
                notifyStartCompletion: notifyStartCompletion
            )
        }
    }

    private func retryExitedOutputRetirement(_ pending: BrokerExitedOutputRetirement) {
        startCompletionPending = true
        exitedOutputRetirementInFlight = true
        exitedOutputResolutionInFlight = true
        failureRecoveryCoordinator.retireCompletedSession(pending.sessionID) { [self] retirementError in
            DispatchQueue.main.async {
                self.finishExitedOutputRetirement(
                    pending,
                    retirementError: retirementError,
                    notifyStartCompletion: true
                )
            }
        }
    }

    private func finishExitedOutputRetirement(
        _ pending: BrokerExitedOutputRetirement,
        retirementError: Error?,
        notifyStartCompletion: Bool
    ) {
        guard brokerSessionID == pending.sessionID,
              pendingExitedOutputRetirement?.sessionID == pending.sessionID else { return }
        exitedOutputRetirementInFlight = false
        // Teardown suppresses the ordinary activation completion while this
        // cleanup owns the exited session. The controller still needs one final
        // ownership publication before quit persists state: success clears the
        // retired ID, while cleanup failure keeps the retryable ID authoritative.
        let teardownSuppressedStartCompletion = !exitedOutputTeardownCompletions.isEmpty
            && !startCompletionPending

        let completionWarning = retirementError.flatMap {
            isCompletedRetirementWarning($0) ? $0 : nil
        }
        if let retirementError, completionWarning == nil {
            startFailureDescription = "\(pending.outputFailureDescription); failed to retire completed broker session: \(retirementError)"
            startFailureKind = .failed
        } else {
            if let completionWarning {
                startFailureDescription = "\(pending.outputFailureDescription); broker retirement completed with warning: \(completionWarning)"
                startFailureKind = .failed
            } else {
                startFailureDescription = pending.outputFailureDescription
                startFailureKind = pending.outputFailureKind
            }
            pendingExitedOutputRetirement = nil
            brokerSessionID = nil
            agentStatusOwnerToken = nil
        }
        revokeOutputDeliveryOwnership()
        sessionIOReady = false
        let publishedFailure = TerminalSessionFailure(
            kind: startFailureKind ?? pending.outputFailureKind,
            description: startFailureDescription ?? pending.outputFailureDescription
        )
        publishSessionFailure(publishedFailure)
        if let exitCode = pending.observedExitCode, !didNotifyTermination {
            didNotifyTermination = true
            terminationHandler?(exitCode)
        }
        completeReattachStartIfNeeded(notifyStartCompletion)
        if teardownSuppressedStartCompletion {
            startCompletionHandler?()
        }
        finishExitedOutputResolution()
    }

    private func finishExitedOutputResolution() {
        exitedOutputResolutionInFlight = false
        if runningSessionTeardownProbeInFlight {
            finishRunningSessionTeardown()
            return
        }
        let completions = exitedOutputTeardownCompletions
        exitedOutputTeardownCompletions.removeAll()
        let outcome = currentCleanupOutcome()
        completions.forEach { $0(outcome) }
        if notifyStartAfterExitedOutputResolution {
            publishInterruptedExitedOutputRecoveryIfNeeded()
            notifyStartAfterExitedOutputResolution = false
            if startCompletionPending {
                startCompletionPending = false
                startCompletionHandler?()
            }
        }
    }

    private func completeReattachStartIfNeeded(_ notifyStartCompletion: Bool) {
        guard notifyStartCompletion, startCompletionPending else { return }
        publishInterruptedExitedOutputRecoveryIfNeeded()
        startCompletionPending = false
        startCompletionHandler?()
    }

    private func publishInterruptedExitedOutputRecoveryIfNeeded() {
        guard notifyStartAfterExitedOutputResolution,
              startFailureDescription == nil,
              sessionFailure == nil else { return }
        startFailureDescription = "Exited session recovery was interrupted by teardown; reconnect to resume final output or start a replacement"
        startFailureKind = .failed
    }

    private func restoreScrollbackReplay(for sessionID: BrokerSessionID) {
        do {
            let replay = try coordinator.readScrollbackReplay(
                sessionID,
                maxBytes: ScrollbackPersistencePolicy.maxReplayBytesOnReattach
            )
            lastScrollbackReplay = replay
            guard !replay.data.isEmpty else { return }
            feedStatusLine(scrollbackReplayStatus(for: replay))
            let bytes = Array(replay.data)
            terminalView.feed(byteArray: bytes[...])
            outputHandler?()
        } catch {
            // Scrollback corruption must not turn a successfully reattached live
            // process into a stale tab. Surface the recovery plainly in the
            // terminal, then continue with live output from the broker.
            lastScrollbackReplay = nil
            feedStatusLine(
                "Holoscape reattached the live session, but could not restore its persisted scrollback (\(error)). The corrupted tail was skipped; new output will continue normally."
            )
            outputHandler?()
            NSLog("Broker-backed terminal scrollback replay failed for \(sessionID.rawValue): \(error)")
        }
    }

    private func applyScrollbackReplay(_ result: ScrollbackReplayResult, for sessionID: BrokerSessionID) {
        if let replay = result.replay {
            lastScrollbackReplay = replay
            guard !replay.data.isEmpty else { return }
            feedStatusLine(scrollbackReplayStatus(for: replay))
            terminalView.feed(byteArray: Array(replay.data)[...])
            outputHandler?()
        } else if let error = result.error {
            lastScrollbackReplay = nil
            feedStatusLine("Holoscape reattached the live session, but could not restore its persisted scrollback (\(error)). The corrupted tail was skipped; new output will continue normally.")
            outputHandler?()
            NSLog("Broker-backed terminal scrollback replay failed for \(sessionID.rawValue): \(error)")
        }
    }

    private func scrollbackReplayStatus(for replay: ScrollbackReplay) -> String {
        let source: String
        switch replay.source {
        case .liveBrokerMemory:
            source = "live broker memory"
        case .persistedDiskTail:
            source = "persisted disk scrollback"
        case .unknown:
            source = "broker scrollback"
        }
        return "Holoscape restored \(replay.data.count) bytes from \(source). Older output beyond the \(replay.maxBytes)-byte replay cap is not retained."
    }

    private func feedStatusLine(_ message: String) {
        let bytes = Array("\r\n[\(message)]\r\n".utf8)
        terminalView.feed(byteArray: bytes[...])
    }

    func send(_ bytes: [UInt8]) {
        guard let brokerSessionID else {
            // Keystrokes can still reach the view of a stale or disconnected tab.
            // There is no live session to write to, and that is not a broker host
            // outage, so log and ignore rather than trapping the app.
            NSLog("Broker-backed terminal input ignored: no live broker session")
            return
        }
        guard sessionFailure == nil else {
            // The outage (or dropped session) was already reported to the tab,
            // which is showing its recovery guidance; late keystrokes are inert.
            return
        }
        guard let deliveryGeneration = activeOutputDeliveryGeneration else { return }
        inputWriteLane.enqueue(
            sessionID: brokerSessionID,
            bytes: bytes,
            write: { [inputCoordinator] id, queuedBytes in
                try inputCoordinator.sendInput(id, bytes: queuedBytes)
            },
            onSuccess: { [outputReadLane] id in
                // Keep every production output read on the single output lane.
                // A direct main-actor poll can otherwise overtake a sample whose
                // bytes were drained off-main but not yet delivered to SwiftTerm.
                outputReadLane.wake(sessionID: id)
            },
            onFailure: { [weak self] id, error in
                Task { @MainActor [weak self] in
                    self?.reportSessionFailure(error, for: id, deliveryGeneration: deliveryGeneration)
                }
            }
        )
    }

    func setOutputHandler(_ handler: (() -> Void)?) {
        outputHandler = handler
        if handler == nil {
            stopOutputPump()
        } else if brokerSessionID != nil, sessionIOReady, sessionFailure == nil {
            startOutputPump()
        }
    }

    func setSessionFailureHandler(_ handler: ((TerminalSessionFailure) -> Void)?) {
        sessionFailureHandler = handler
    }

    func setStartCompletionHandler(_ handler: (() -> Void)?) {
        startCompletionHandler = handler
    }

    func setUserInputHandler(_ handler: ((ArraySlice<UInt8>) -> Void)?) {
        userInputHandler = handler
    }

    func setHostCurrentDirectoryHandler(_ handler: ((String?) -> Void)?) {
        hostCurrentDirectoryHandler = handler
    }

    func setTerminationHandler(_ handler: ((Int32?) -> Void)?) {
        terminationHandler = handler
    }

    func lastLines(_ count: Int) -> [String] {
        terminalView.lastLines(count)
    }

    func detachBrokerSession(completion: @escaping @MainActor () -> Void) {
        detachBrokerSessionInternal { _ in completion() }
    }

    func detachBrokerSessionForCleanup(
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    ) {
        detachBrokerSessionInternal(completion: completion)
    }

    func detachBrokerSessionPreservingOutput(completion: @escaping @MainActor () -> Void) {
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
                completePreservingOutputDetach()
            }
            return
        }
        // Cancel asynchronous reattach authority before waiting on either output
        // lane. Otherwise a late replay/final-drain callback can acknowledge and
        // retire bytes after Quit has promised to preserve them for relaunch.
        reattachGeneration &+= 1
        startCompletionPending = false
        preservesUnreadOutputForTermination = true
        revokeOutputDeliveryOwnership()
        sessionIOReady = false
        stopOutputPump()
        outputReadLane.finishWithoutConsuming { [self] in
            DispatchQueue.main.async {
                self.finishPreservingOutputDetach()
            }
        }
    }

    private func finishPreservingOutputDetach() {
        if reattachWorkInFlight {
            reattachWorkCompletionWaiters.append { [self] in
                finishPreservingOutputDetach()
            }
            return
        }
        if exitedOutputResolutionInFlight || runningSessionTeardownProbeInFlight {
            exitedOutputTeardownCompletions.append { [self] _ in
                finishPreservingOutputDetach()
            }
            return
        }
        if let brokerSessionID {
            failureRecoveryCoordinator.detach(brokerSessionID) { [self] error in
                DispatchQueue.main.async {
                    if let error {
                        NSLog("Broker-backed terminal app-termination detach failed: \(error)")
                    }
                    self.completePreservingOutputDetach()
                }
            }
            return
        }
        if let untrackedBrokerSessionID {
            retireUntrackedForTeardown(untrackedBrokerSessionID) { [self] in
                completePreservingOutputDetach()
            }
            return
        }
        completePreservingOutputDetach()
    }

    private func completePreservingOutputDetach() {
        preservesUnreadOutputForTermination = false
        preservingOutputDetachInFlight = false
        let completions = preservingOutputDetachCompletions
        preservingOutputDetachCompletions.removeAll()
        completions.forEach { $0() }
        let restart = restartAfterPreservingOutputDetach
        restartAfterPreservingOutputDetach = nil
        restart?()
    }

    func retireBrokerSessionForClose(
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    ) {
        // User close supersedes reconnect intent from a denied/timed-out quit.
        // Join the preserving detach before retiring its now-detached identity.
        restartAfterPreservingOutputDetach = nil
        if preservingOutputDetachInFlight {
            startCompletionPending = false
            preservingOutputDetachCompletions.append { [self] in
                retireBrokerSessionForClose(completion: completion)
            }
            return
        }
        if freshStartPending {
            freshStartCancelled = true
            restartAfterCancelledFreshStart = nil
            freshStartTeardownCompletions.append { completion(.completed) }
            return
        }
        revokeOutputDeliveryOwnership()
        sessionIOReady = false
        stopOutputPump()
        outputReadLane.finishWithoutConsuming { [self] in
            DispatchQueue.main.async { [self] in
                finishCloseRetirement(completion: completion)
            }
        }
    }

    private func finishCloseRetirement(
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    ) {
        if let brokerSessionID {
            failureRecoveryCoordinator.markErrored(brokerSessionID) { [self] error in
                DispatchQueue.main.async { [self] in
                    if let error, !isCompletedRetirementWarning(error) {
                        completion(.retryableFailure(cleanupFailure(from: error)))
                        return
                    }
                    self.brokerSessionID = nil
                    self.agentStatusOwnerToken = nil
                    self.pendingExitedOutputRetirement = nil
                    completion(.completed)
                }
            }
            return
        }
        if let untrackedBrokerSessionID {
            failureRecoveryCoordinator.retireUntrackedSession(untrackedBrokerSessionID) { [self] error in
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

    private func detachBrokerSessionInternal(
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    ) {
        // A host reattach may still be executing off-main. Invalidate its token
        // before detaching so its late result cannot reopen I/O or publish the
        // owning controller as active after teardown.
        reattachGeneration &+= 1
        inputWriteLane.close()
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
            revokeOutputDeliveryOwnership()
            sessionIOReady = false
            stopOutputPump()
            startCompletionPending = false
            notifyStartAfterExitedOutputResolution = false
            exitedOutputTeardownCompletions.append(completion)
            return
        }
        if let brokerSessionID, exitedOutputResolutionClaim.joinOrStop(
            brokerSessionID,
            stop: { [outputReadLane] in outputReadLane.stop() }
        ) {
            // The output lane has observed an exit outcome and queued its main-
            // actor publication. Join that claimed generation instead of racing
            // it with a teardown probe during the queue handoff window.
            revokeOutputDeliveryOwnership()
            sessionIOReady = false
            stopOutputPump()
            startCompletionPending = false
            notifyStartAfterExitedOutputResolution = false
            exitedOutputResolutionInFlight = true
            exitedOutputTeardownCompletions.append(completion)
            return
        }
        startCompletionPending = false
        if let brokerSessionID, !didNotifyTermination, sessionIOReady,
           activeOutputDeliveryGeneration != nil {
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
            revokeOutputDeliveryOwnership()
            sessionIOReady = false
            stopOutputPump()
            exitedOutputResolutionInFlight = true
            runningSessionTeardownProbeInFlight = true
            exitedOutputTeardownCompletions.append(completion)
            outputReadLane.finishForTeardown(
                sessionID: brokerSessionID,
                read: { [outputCoordinator] id in
                    try outputCoordinator.snapshotAvailableOutput(id)
                },
                acknowledge: { [outputCoordinator] id, generation in
                    try outputCoordinator.acknowledgeOutput(id, through: generation)
                },
                terminationStatus: { [outputCoordinator] id in
                    try outputCoordinator.terminationStatusIfStopped(id)
                },
                finishTermination: { [outputCoordinator] id, exitCode in
                    try outputCoordinator.finishTermination(id, exitCode: exitCode)
                },
                onTermination: teardownOutputTerminationHandler(),
                onStoppedFailure: { [weak self] id, exitCode, error in
                    DispatchQueue.main.async {
                        self?.retireExitedSessionAfterOutputFailure(
                            id,
                            error: error,
                            observedExitCode: exitCode,
                            notifyStartCompletion: false
                        )
                    }
                },
                onStillRunningOrStatusFailure: { [weak self] error in
                    DispatchQueue.main.async {
                        self?.finishRunningSessionTeardownProbe(error: error)
                    }
                }
            )
            return
        }
        revokeOutputDeliveryOwnership()
        sessionIOReady = false
        stopOutputPump()
        if let brokerSessionID, !didNotifyTermination {
            if coordinator.requiresOffMainBrokerWork {
                failureRecoveryCoordinator.detach(brokerSessionID) { error in
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

    private func finishRunningSessionTeardownProbe(error: Error?) {
        guard exitedOutputResolutionInFlight else { return }
        exitedOutputResolutionInFlight = false
        if let error {
            publishSessionFailure(
                TerminalSessionFailure(
                    kind: classifyStartFailure(error),
                    description: String(describing: error)
                )
            )
        }
        revokeOutputDeliveryOwnership()
        sessionIOReady = false
        stopOutputPump()
        guard let brokerSessionID, !didNotifyTermination else {
            finishRunningSessionTeardown()
            return
        }
        let finish: @Sendable (Error?) -> Void = { error in
            if let error {
                NSLog("Broker-backed terminal detach failed: \(error)")
            }
            DispatchQueue.main.async { [self] in
                finishRunningSessionTeardown(detachError: error)
            }
        }
        if coordinator.requiresOffMainBrokerWork {
            failureRecoveryCoordinator.detach(brokerSessionID, completion: finish)
        } else {
            do {
                _ = try coordinator.detach(brokerSessionID)
                finish(nil)
            } catch {
                finish(error)
            }
        }
    }

    private func finishRunningSessionTeardown(detachError: Error? = nil) {
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
            startCompletionHandler?()
        }
    }

    private func currentCleanupOutcome() -> TerminalCleanupOutcome {
        guard pendingExitedOutputRetirement != nil else { return .completed }
        return .retryableFailure(TerminalSessionFailure(
            kind: startFailureKind ?? .failed,
            description: startFailureDescription ?? "Completed broker session retirement remains pending"
        ))
    }

    private func cleanupFailure(from error: Error) -> TerminalSessionFailure {
        TerminalSessionFailure(
            kind: classifyStartFailure(error),
            description: String(describing: error)
        )
    }

    func pollOutputOnce() {
        guard sessionIOReady, sessionFailure == nil else { return }
        guard let brokerSessionID else { return }
        guard let deliveryGeneration = activeOutputDeliveryGeneration else { return }
        let handoffGeneration = activeOutputHandoffGeneration ?? beginOutputHandoff()
        outputReadLane.pollOnce(
            sessionID: brokerSessionID,
            read: { [outputCoordinator] id in
                try outputCoordinator.snapshotAvailableOutput(id)
            },
            acknowledge: { [outputCoordinator] id, generation in
                try outputCoordinator.acknowledgeOutput(id, through: generation)
            },
            terminationStatus: { [outputCoordinator] id in
                try outputCoordinator.terminationStatusIfStopped(id)
            },
            finishTermination: { [outputCoordinator] id, exitCode in
                try outputCoordinator.finishTermination(id, exitCode: exitCode)
            },
            exitResolutionClaim: exitedOutputResolutionClaim,
            onSample: outputSampleHandler(
                deliveryGeneration: deliveryGeneration,
                handoffGeneration: handoffGeneration
            ),
            onTermination: outputTerminationHandler(deliveryGeneration: deliveryGeneration),
            onFailure: outputFailureHandler(deliveryGeneration: deliveryGeneration)
        )
    }

    func resizeToCurrentGrid() {
        guard sessionIOReady, sessionFailure == nil else { return }
        guard let brokerSessionID else {
            NSLog("Broker-backed terminal resize ignored: no live broker session")
            return
        }
        guard let deliveryGeneration = activeOutputDeliveryGeneration else { return }
        let size = currentGridSize
        if coordinator.requiresOffMainBrokerWork {
            failureRecoveryCoordinator.resize(brokerSessionID, size: size) { [weak self] error in
                guard let error else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.reportSessionFailure(error, for: brokerSessionID, deliveryGeneration: deliveryGeneration)
                }
            }
        } else {
            do {
                try coordinator.resize(brokerSessionID, size: size)
            } catch {
                reportSessionFailure(error, for: brokerSessionID, deliveryGeneration: deliveryGeneration)
            }
        }
    }

    fileprivate func terminalViewDidResize() {
        resizeToCurrentGrid()
    }

    fileprivate func terminalViewDidUpdateHostCurrentDirectory(_ directory: String?) {
        hostCurrentDirectoryHandler?(directory)
    }

    private func startOutputPump() {
        guard sessionIOReady, let brokerSessionID else { return }
        guard let deliveryGeneration = activeOutputDeliveryGeneration else { return }
        let supportsOutputAvailabilityMonitoring: Bool
        do {
            supportsOutputAvailabilityMonitoring = try coordinator.supportsOutputAvailabilityMonitoring(brokerSessionID)
        } catch {
            reportSessionFailure(error, for: brokerSessionID, deliveryGeneration: deliveryGeneration)
            return
        }
        let handoffGeneration = beginOutputHandoff()
        outputReadLane.start(
            sessionID: brokerSessionID,
            mode: supportsOutputAvailabilityMonitoring ? .outputAvailabilitySignal : .periodicPolling,
            read: { [outputCoordinator] id in
                try outputCoordinator.snapshotAvailableOutput(id)
            },
            acknowledge: { [outputCoordinator] id, generation in
                try outputCoordinator.acknowledgeOutput(id, through: generation)
            },
            terminationStatus: { [outputCoordinator] id in
                try outputCoordinator.terminationStatusIfStopped(id)
            },
            finishTermination: { [outputCoordinator] id, exitCode in
                try outputCoordinator.finishTermination(id, exitCode: exitCode)
            },
            exitResolutionClaim: exitedOutputResolutionClaim,
            onSample: outputSampleHandler(
                deliveryGeneration: deliveryGeneration,
                handoffGeneration: handoffGeneration
            ),
            onTermination: outputTerminationHandler(deliveryGeneration: deliveryGeneration),
            onFailure: outputFailureHandler(deliveryGeneration: deliveryGeneration)
        )
        do {
            try coordinator.setOutputAvailabilityHandler(brokerSessionID) { [outputReadLane] id in
                outputReadLane.wake(sessionID: id)
            }
        } catch {
            reportSessionFailure(error, for: brokerSessionID, deliveryGeneration: deliveryGeneration)
        }
    }

    private func handleOutputPumpSample(_ data: Data, for brokerSessionID: BrokerSessionID) {
        if !data.isEmpty {
            let bytes = Array(data)
            terminalView.feed(byteArray: bytes[...])
            outputHandler?()
        }
    }

    private func outputSampleHandler(
        deliveryGeneration: UInt,
        handoffGeneration: UInt
    ) -> @Sendable (BrokerSessionID, Data) -> Bool {
        let outputDeliveryTimeout = self.outputDeliveryTimeout
        let outputDeliveryGate = self.outputDeliveryGate
        return { [weak self] id, data in
            // Empty polls carry no terminal work or transactional generation.
            // Accept them on the output lane so an unavailable main actor cannot
            // turn an otherwise healthy idle session into a delivery failure;
            // the caller still proceeds to its termination-status check.
            guard !data.isEmpty else { return true }
            // The serial lane does not perform liveness/exit RPCs until the main
            // actor has consumed this sample, preserving final-byte ordering
            // without making the main actor call the broker.
            let acceptance = BrokerOutputDeliveryAcceptance()
            guard outputDeliveryGate.install(acceptance, generation: handoffGeneration) else {
                return false
            }
            defer { outputDeliveryGate.remove(acceptance) }
            DispatchQueue.main.async { [weak self] in
                defer { acceptance.signalCompletion() }
                guard let self,
                      self.activeOutputDeliveryGeneration == deliveryGeneration,
                      self.brokerSessionID == id,
                      self.sessionIOReady,
                      self.sessionFailure == nil,
                      acceptance.beginDelivery() else { return }
                var dataToRender = data
                if let presented = self.presentedUnacknowledgedOutput,
                   presented.sessionID == id {
                    if data.starts(with: presented.data) {
                        dataToRender = Data(data.dropFirst(presented.data.count))
                    }
                    self.presentedUnacknowledgedOutput = nil
                }
                self.handleOutputPumpSample(dataToRender, for: id)
                acceptance.finishDelivery()
            }
            if acceptance.wait(timeout: outputDeliveryTimeout) == .timedOut,
               acceptance.cancelIfPending() {
                DispatchQueue.main.async { [weak self] in
                    self?.reportSessionFailure(
                        BrokerOutputDeliveryFailure.timedOut,
                        for: id,
                        deliveryGeneration: deliveryGeneration
                    )
                }
                return false
            }
            // Once the main actor has claimed the sample it owns completion;
            // cancellation after that point could replay bytes already rendered.
            if acceptance.isDelivering {
                acceptance.wait()
            }
            return acceptance.wasAccepted
        }
    }

    private func outputTerminationHandler(deliveryGeneration: UInt) -> @Sendable (BrokerSessionID, Int32, Error?) -> Void {
        { [weak self] id, exitCode, exitWarning in
            Task { @MainActor [weak self] in
                guard let self,
                      self.exitedOutputResolutionClaim.consume(for: id) else { return }
                guard self.brokerSessionID == id, !self.didNotifyTermination else {
                    if self.exitedOutputResolutionInFlight {
                        self.finishExitedOutputResolution()
                    }
                    return
                }
                self.exitedOutputResolutionInFlight = true
                self.outputReadLane.stop()
                self.sessionIOReady = false
                self.inputWriteLane.close()
                if let exitWarning {
                    self.publishSessionFailure(
                        TerminalSessionFailure(kind: .failed, description: String(describing: exitWarning))
                    )
                }
                let exitWarningDescription = exitWarning.map(String.init(describing:))

                let completion: @Sendable (Error?) -> Void = { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self,
                              self.brokerSessionID == id,
                              self.exitedOutputResolutionInFlight,
                              !self.didNotifyTermination else { return }
                        let completionWarning = error.flatMap {
                            self.isCompletedRetirementWarning($0) ? $0 : nil
                        }
                        if let error, completionWarning == nil {
                            let failureDescription = exitWarningDescription.map {
                                "\($0); failed to retire completed broker session: \(error)"
                            } ?? String(describing: error)
                            self.retainExitedOutputRetirement(
                                sessionID: id,
                                failureDescription: failureDescription,
                                failureKind: self.classifyStartFailure(error),
                                observedExitCode: exitCode
                            )
                            self.reportSessionFailure(
                                BrokerSessionCompositeFailure(description: failureDescription),
                                for: id,
                                deliveryGeneration: deliveryGeneration
                            )
                            self.didNotifyTermination = true
                            self.terminationHandler?(exitCode)
                            self.finishExitedOutputResolution()
                            return
                        }
                        self.didNotifyTermination = true
                        self.revokeOutputDeliveryOwnership()
                        self.brokerSessionID = nil
                        self.agentStatusOwnerToken = nil
                        if let completionWarning,
                           self.sessionFailure == nil || self.isCompletedOutputRetirementWarning(completionWarning) {
                            self.publishSessionFailure(
                                TerminalSessionFailure(
                                    kind: .failed,
                                    description: String(describing: completionWarning)
                                )
                            )
                        }
                        self.terminationHandler?(exitCode)
                        self.finishExitedOutputResolution()
                    }
                }

                // Durable exit was already published by the output lane. Remove
                // the retained runtime object before releasing the tab's broker
                // identity; otherwise closing the disconnected tab can make the
                // completed generation appear as a recovered session next launch.
                if self.coordinator.requiresOffMainBrokerWork {
                    self.failureRecoveryCoordinator.retireCompletedSession(id, completion: completion)
                } else {
                    do {
                        try self.coordinator.retireCompletedSession(id)
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            }
        }
    }

    private func teardownOutputTerminationHandler() -> @Sendable (BrokerSessionID, Int32, Error?) -> Void {
        { [weak self] id, exitCode, exitWarning in
            Task { @MainActor [weak self] in
                guard let self,
                      self.brokerSessionID == id,
                      self.exitedOutputResolutionInFlight,
                      !self.didNotifyTermination else { return }
                self.outputReadLane.stop()
                self.sessionIOReady = false
                self.inputWriteLane.close()
                if let exitWarning {
                    self.publishSessionFailure(
                        TerminalSessionFailure(kind: .failed, description: String(describing: exitWarning))
                    )
                }
                let exitWarningDescription = exitWarning.map(String.init(describing:))

                let completion: @Sendable (Error?) -> Void = { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self,
                              self.brokerSessionID == id,
                              self.exitedOutputResolutionInFlight,
                              !self.didNotifyTermination else { return }
                        let completionWarning = error.flatMap {
                            self.isCompletedRetirementWarning($0) ? $0 : nil
                        }
                        if let error, completionWarning == nil {
                            let failureDescription = exitWarningDescription.map {
                                "\($0); failed to retire completed broker session: \(error)"
                            } ?? String(describing: error)
                            self.retainExitedOutputRetirement(
                                sessionID: id,
                                failureDescription: failureDescription,
                                failureKind: self.classifyStartFailure(error),
                                observedExitCode: exitCode
                            )
                            self.publishSessionFailure(
                                TerminalSessionFailure(
                                    kind: self.classifyStartFailure(error),
                                    description: failureDescription
                                )
                            )
                            self.didNotifyTermination = true
                            self.terminationHandler?(exitCode)
                            self.finishExitedOutputResolution()
                            return
                        }
                        self.didNotifyTermination = true
                        self.revokeOutputDeliveryOwnership()
                        self.brokerSessionID = nil
                        self.agentStatusOwnerToken = nil
                        if let completionWarning,
                           self.sessionFailure == nil || self.isCompletedOutputRetirementWarning(completionWarning) {
                            self.publishSessionFailure(
                                TerminalSessionFailure(
                                    kind: .failed,
                                    description: String(describing: completionWarning)
                                )
                            )
                        }
                        self.terminationHandler?(exitCode)
                        self.finishExitedOutputResolution()
                    }
                }

                if self.coordinator.requiresOffMainBrokerWork {
                    self.failureRecoveryCoordinator.retireCompletedSession(id, completion: completion)
                } else {
                    do {
                        try self.coordinator.retireCompletedSession(id)
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            }
        }
    }

    private func outputFailureHandler(deliveryGeneration: UInt) -> @Sendable (BrokerSessionID, Int32?, Error, Data?) -> Void {
        { [weak self] id, observedExitCode, error, presentedUnacknowledgedData in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let presentedUnacknowledgedData, !presentedUnacknowledgedData.isEmpty {
                    self.presentedUnacknowledgedOutput = (id, presentedUnacknowledgedData)
                }
                if self.exitedOutputResolutionClaim.consume(for: id) {
                    guard self.brokerSessionID == id, !self.didNotifyTermination else {
                        if self.exitedOutputResolutionInFlight {
                            self.finishExitedOutputResolution()
                        }
                        return
                    }
                    self.exitedOutputResolutionInFlight = true
                    if let coordinatorError = error as? BrokerSessionCoordinator.CoordinatorError,
                       case let .exitCodeMismatch(_, _, observedExitCode) = coordinatorError {
                        self.retireMismatchedExitedSession(
                            id,
                            observedExitCode: observedExitCode,
                            mismatchError: error,
                            deliveryGeneration: deliveryGeneration
                        )
                    } else {
                        self.retireExitedSessionAfterOutputFailure(
                            id,
                            error: error,
                            observedExitCode: observedExitCode,
                            notifyStartCompletion: false
                        )
                    }
                    return
                }
                if self.isCompletedExitWarning(error) {
                    // Exit truth was durably finalized before this cleanup warning
                    // was returned. Keep termination delivery alive while still
                    // exposing the descriptor failure to the owning controller.
                    self.publishSessionFailure(
                        TerminalSessionFailure(kind: .failed, description: String(describing: error))
                    )
                    return
                }
                if let coordinatorError = error as? BrokerSessionCoordinator.CoordinatorError,
                   case let .exitCodeMismatch(_, _, observedExitCode) = coordinatorError {
                    self.retireMismatchedExitedSession(
                        id,
                        observedExitCode: observedExitCode,
                        mismatchError: error,
                        deliveryGeneration: deliveryGeneration
                    )
                    return
                }
                self.reportSessionFailure(error, for: id, deliveryGeneration: deliveryGeneration)
            }
        }
    }

    private func isCompletedExitWarning(_ error: Error) -> Bool {
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

    private func isCompletedRetirementWarning(_ error: Error) -> Bool {
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

    private func isCompletedOutputRetirementWarning(_ error: Error) -> Bool {
        if case NativePTYBrokerSessionRuntime.RuntimeError.retirementCompletedWithOutputFailure = error {
            return true
        }
        if case let BrokerSessionHostClientRuntime.ClientError.hostFailure(code, _) = error {
            return code == "retirement-completed-with-output-failure"
        }
        return false
    }

    private func retireMismatchedExitedSession(
        _ id: BrokerSessionID,
        observedExitCode: Int32,
        mismatchError: Error,
        deliveryGeneration: UInt
    ) {
        exitedOutputResolutionInFlight = true
        exitedOutputRetirementInFlight = true
        let completion: @Sendable (Error?) -> Void = { [weak self] retirementError in
            DispatchQueue.main.async {
                guard let self,
                      self.brokerSessionID == id,
                      self.exitedOutputResolutionInFlight,
                      !self.didNotifyTermination else { return }
                self.exitedOutputRetirementInFlight = false
                let completionWarning = retirementError.flatMap {
                    self.isCompletedRetirementWarning($0) ? $0 : nil
                }
                if let retirementError, completionWarning == nil {
                    let combined = BrokerSessionCompositeFailure(
                        description: "\(mismatchError); failed to retire completed broker session: \(retirementError)"
                    )
                    self.retainExitedOutputRetirement(
                        sessionID: id,
                        failureDescription: combined.description,
                        failureKind: .failed,
                        observedExitCode: observedExitCode
                    )
                    self.reportSessionFailure(
                        combined,
                        for: id,
                        deliveryGeneration: deliveryGeneration
                    )
                    self.didNotifyTermination = true
                    self.terminationHandler?(observedExitCode)
                    self.finishExitedOutputResolution()
                    return
                }
                self.didNotifyTermination = true
                self.revokeOutputDeliveryOwnership()
                self.brokerSessionID = nil
                self.agentStatusOwnerToken = nil
                let failureDescription: String
                if let completionWarning {
                    failureDescription = "\(mismatchError); broker retirement completed with warning: \(completionWarning)"
                } else {
                    failureDescription = String(describing: mismatchError)
                }
                self.publishSessionFailure(
                    TerminalSessionFailure(kind: .failed, description: failureDescription)
                )
                self.terminationHandler?(observedExitCode)
                self.finishExitedOutputResolution()
            }
        }

        if coordinator.requiresOffMainBrokerWork {
            failureRecoveryCoordinator.retireCompletedSession(id, completion: completion)
        } else {
            do {
                try coordinator.retireCompletedSession(id)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    private func stopOutputPump() {
        activeOutputHandoffGeneration = nil
        outputDeliveryGate.close()
        if let brokerSessionID {
            try? coordinator.setOutputAvailabilityHandler(brokerSessionID, handler: nil)
        }
        outputReadLane.stop()
    }

    /// Record a mid-session broker failure once, stop polling, and report it so
    /// the owning tab can downgrade to an explicit recovery state.
    ///
    /// The broker host disappearing underneath a running tab is an expected
    /// runtime condition, so it is reported through the session-failure boundary
    /// instead of trapping. The durable broker handle is preserved for the
    /// retryable cases so retry reattaches the same session rather than starting
    /// a replacement.
    private func reportSessionFailure(
        _ error: Error,
        for sessionID: BrokerSessionID,
        deliveryGeneration: UInt
    ) {
        guard brokerSessionID == sessionID,
              activeOutputDeliveryGeneration == deliveryGeneration else {
            NSLog("Ignoring delayed broker failure for inactive session \(sessionID.rawValue): \(error)")
            return
        }
        let kind = classifyStartFailure(error)
        let description = String(describing: error)
        inputWriteLane.close()
        stopOutputPump()
        revokeOutputDeliveryOwnership()

        if kind == .brokerSessionStale,
           isScrollbackPersistenceFailure(error) || isOutputMonitoringFailure(error) {
            beginOutputFailureRecovery(error, for: sessionID)
            return
        }

        switch kind {
        case .brokerHostUnavailable, .failed:
            // The host is unreachable (or the failure is unclassified) but the
            // session may still be alive: keep the handle so retry reattaches it.
            break
        case .brokerSessionStale:
            // The broker no longer owns the session: hand the dead identity to the
            // tab and drop the live handle so retry starts a replacement.
            brokerSessionID = nil
            sessionIOReady = false
            staleBrokerSessionID = sessionID
        }

        publishSessionFailure(TerminalSessionFailure(kind: kind, description: description))
    }

    private func beginOutputFailureRecovery(_ error: Error, for sessionID: BrokerSessionID) {
        guard recoveringBrokerSessionID == nil else { return }
        recoveringBrokerSessionID = sessionID
        let originalDescription = String(describing: error)
        failureRecoveryCoordinator.markErrored(sessionID) { [weak self] recoveryError in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.recoveringBrokerSessionID == sessionID,
                      self.brokerSessionID == sessionID else { return }
                self.recoveringBrokerSessionID = nil

                if let recoveryError,
                   !self.isCompletedRetirementWarning(recoveryError) {
                    self.publishSessionFailure(
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
                self.brokerSessionID = nil
                self.sessionIOReady = false
                self.staleBrokerSessionID = sessionID
                self.publishSessionFailure(
                    TerminalSessionFailure(
                        kind: .brokerSessionStale,
                        description: originalDescription + completedWarningDescription
                    )
                )
            }
        }
    }

    private func publishSessionFailure(_ failure: TerminalSessionFailure) {
        guard sessionFailure != failure else {
            NSLog("Broker-backed terminal session still failing: \(failure.description)")
            return
        }
        sessionFailure = failure
        NSLog("Broker-backed terminal session failed (\(failure.kind)): \(failure.description)")
        sessionFailureHandler?(failure)
    }

    @discardableResult
    private func beginOutputDeliveryOwnership() -> UInt {
        nextOutputDeliveryGeneration &+= 1
        activeOutputDeliveryGeneration = nextOutputDeliveryGeneration
        return nextOutputDeliveryGeneration
    }

    private func revokeOutputDeliveryOwnership() {
        activeOutputDeliveryGeneration = nil
        activeOutputHandoffGeneration = nil
        outputDeliveryGate.close()
    }

    private func beginOutputHandoff() -> UInt {
        let generation = outputDeliveryGate.open()
        activeOutputHandoffGeneration = generation
        return generation
    }

    private func isScrollbackPersistenceFailure(_ error: Error) -> Bool {
        if let runtimeError = error as? NativePTYBrokerSessionRuntime.RuntimeError,
           case .scrollbackPersistenceFailed = runtimeError {
            return true
        }
        if case let BrokerSessionHostClientRuntime.ClientError.hostFailure(code, _) = error {
            return code == "scrollback-persistence-failed"
        }
        return false
    }

    private func isOutputMonitoringFailure(_ error: Error) -> Bool {
        if let runtimeError = error as? NativePTYBrokerSessionRuntime.RuntimeError,
           case .outputMonitoringFailed = runtimeError {
            return true
        }
        if case let BrokerSessionHostClientRuntime.ClientError.hostFailure(code, _) = error {
            return code == "output-monitoring-failed"
        }
        return false
    }

    private func classifyStartFailure(_ error: Error) -> TerminalStartFailureKind {
        if isCompletedRetirementWarning(error) {
            return .brokerSessionStale
        }
        if let coordinatorError = error as? BrokerSessionCoordinator.CoordinatorError {
            switch coordinatorError {
            case .missingSession, .staleSession:
                return .brokerSessionStale
            case .brokerHostUnavailable:
                return .brokerHostUnavailable
            case .retirementRollbackFailed, .retirementFinalizationFailed,
                 .detachRollbackFailed, .reattachRollbackFailed,
                 .reattachCleanupFailed, .exitRollbackFailed, .exitFinalizationFailed,
                 .exitCodeMismatch, .exitStillPending:
                return .failed
            case .concurrentSessionTransition, .untrackedSession:
                return .failed
            }
        }
        if case BrokerSessionHostClientRuntime.ClientError.transportFailed = error {
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

private final class BrokerBackedTerminalViewDelegate: NSObject, LocalProcessTerminalViewDelegate {
    private weak var owner: BrokerBackedTerminalProcess?

    init(owner: BrokerBackedTerminalProcess) {
        self.owner = owner
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        Task { @MainActor [weak owner] in
            owner?.terminalViewDidResize()
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        // Broker-backed processes are owned by the broker runtime, not SwiftTerm's
        // LocalProcessTerminalView. Termination is observed through the broker
        // polling path so registry state stays authoritative.
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        Task { @MainActor [weak owner] in
            owner?.terminalViewDidUpdateHostCurrentDirectory(directory)
        }
    }
}

private final class BrokerInputCoordinator: @unchecked Sendable {
    private let coordinator: any BrokerSessionCoordinating

    init(_ coordinator: any BrokerSessionCoordinating) {
        self.coordinator = coordinator
    }

    func sendInput(_ id: BrokerSessionID, bytes: [UInt8]) throws {
        try coordinator.sendInput(id, bytes: bytes)
    }
}

private final class BrokerOutputCoordinator: @unchecked Sendable {
    private let coordinator: any BrokerSessionCoordinating

    init(_ coordinator: any BrokerSessionCoordinating) {
        self.coordinator = coordinator
    }

    func snapshotAvailableOutput(_ id: BrokerSessionID) throws -> BrokerOutputSnapshot {
        try coordinator.snapshotAvailableOutput(id)
    }

    func acknowledgeOutput(_ id: BrokerSessionID, through generation: UInt64) throws {
        try coordinator.acknowledgeOutput(id, through: generation)
    }

    /// Check and durably finalize process exit on the same serial lane as output
    /// reads. The lane calls this only after SwiftTerm has consumed the preceding
    /// sample, so final bytes remain visible before exit becomes authoritative.
    func terminationStatusIfStopped(_ id: BrokerSessionID) throws -> Int32? {
        do {
            return try coordinator.terminationStatus(id)
        } catch let error as NativePTYBrokerSessionRuntime.RuntimeError {
            guard case let .exitCompletedWithInputCloseFailure(
                warningID,
                observedExitCode,
                _,
                _
            ) = error, warningID == id else { throw error }
            return observedExitCode
        } catch let error as BrokerSessionHostClientRuntime.ClientError {
            guard case let .exitCompletedWithInputCloseFailure(
                warningID,
                observedExitCode,
                _,
                _
            ) = error, warningID == id else { throw error }
            return observedExitCode
        }
    }

    func finishTermination(_ id: BrokerSessionID, exitCode: Int32) throws -> Error? {
        do {
            _ = try coordinator.exit(id, exitCode: exitCode)
            return nil
        } catch let error as NativePTYBrokerSessionRuntime.RuntimeError {
            guard case .exitCompletedWithInputCloseFailure = error else { throw error }
            return error
        } catch let error as BrokerSessionHostClientRuntime.ClientError {
            switch error {
            case .exitCompletedWithInputCloseFailure:
                return error
            case let .hostFailure(code, _) where code == "exit-completed-with-input-close-failure":
                return error
            default:
                throw error
            }
        }
    }
}

private struct ScrollbackReplayResult: Sendable {
    let replay: ScrollbackReplay?
    let generation: UInt64?
    let error: String?
}

private struct ReattachResult: Sendable {
    let record: Result<BrokerSessionRecord, Error>
    let replay: ScrollbackReplayResult?
}

private final class BrokerFailureRecoveryCoordinator: @unchecked Sendable {
    private let coordinator: any BrokerSessionCoordinating
    private let queue = DispatchQueue(label: "holoscape.broker.failure-recovery", qos: .userInitiated)

    init(_ coordinator: any BrokerSessionCoordinating) {
        self.coordinator = coordinator
    }

    func start(
        _ request: BrokerSessionLaunchRequest,
        channelType: ChannelType,
        label: String?,
        attachedChannelID: UUID?,
        completion: @escaping @Sendable (Result<BrokerSessionRecord, Error>) -> Void
    ) {
        queue.async { [self] in
            completion(Result {
                try coordinator.start(
                    request,
                    channelType: channelType,
                    label: label,
                    attachedChannelID: attachedChannelID
                )
            })
        }
    }

    func reattach(
        _ id: BrokerSessionID,
        attachedChannelID: UUID,
        shouldReplayScrollback: Bool,
        completion: @escaping @Sendable (ReattachResult) -> Void
    ) {
        queue.async { [self] in
            do {
                let record = try coordinator.reattach(id, attachedChannelID: attachedChannelID)
                var replay: ScrollbackReplayResult?
                if shouldReplayScrollback {
                    do {
                        let snapshot = try coordinator.snapshotScrollbackReplay(
                            id,
                            maxBytes: ScrollbackPersistencePolicy.maxReplayBytesOnReattach
                        )
                        replay = ScrollbackReplayResult(
                            replay: snapshot.replay,
                            generation: snapshot.generation,
                            error: nil
                        )
                    } catch {
                        replay = ScrollbackReplayResult(
                            replay: nil,
                            generation: nil,
                            error: String(describing: error)
                        )
                    }
                }
                completion(ReattachResult(record: .success(record), replay: replay))
            } catch {
                completion(ReattachResult(record: .failure(error), replay: nil))
            }
        }
    }

    func markErrored(
        _ id: BrokerSessionID,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        queue.async { [self] in
            do {
                _ = try coordinator.markErrored(id)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func detach(
        _ id: BrokerSessionID,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        queue.async { [self] in
            do {
                _ = try coordinator.detach(id)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func retireUntrackedSession(
        _ id: BrokerSessionID,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        queue.async { [self] in
            do {
                try coordinator.retireUntrackedSession(id)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func retireCompletedSession(
        _ id: BrokerSessionID,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        queue.async { [self] in
            do {
                try coordinator.retireCompletedSession(id)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func readAvailableOutput(
        _ id: BrokerSessionID,
        completion: @escaping @Sendable (Result<BrokerOutputSnapshot, Error>) -> Void
    ) {
        queue.async { [self] in
            completion(Result {
                try coordinator.snapshotAvailableOutput(id)
            })
        }
    }

    func acknowledgeOutput(
        _ id: BrokerSessionID,
        through generation: UInt64,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        queue.async { [self] in
            do {
                try coordinator.acknowledgeOutput(id, through: generation)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    func resize(
        _ id: BrokerSessionID,
        size: TerminalGridSize,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        queue.async { [self] in
            do {
                try coordinator.resize(id, size: size)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }
}

final class BrokerOutputDeliveryAcceptance: @unchecked Sendable {
    private enum State {
        case pending
        case delivering
        case accepted
        case cancelled
    }

    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private var state = State.pending
    private var completionSignaled = false

    func beginDelivery() -> Bool {
        lock.withLock {
            guard state == .pending else { return false }
            state = .delivering
            return true
        }
    }

    func finishDelivery() {
        lock.withLock {
            if state == .delivering {
                state = .accepted
            }
        }
    }

    func cancelIfPending() -> Bool {
        let cancelled = lock.withLock { () -> Bool in
            guard state == .pending else { return false }
            state = .cancelled
            return true
        }
        if cancelled { signalCompletion() }
        return cancelled
    }

    func signalCompletion() {
        let shouldSignal = lock.withLock { () -> Bool in
            guard !completionSignaled else { return false }
            completionSignaled = true
            return true
        }
        if shouldSignal { completion.signal() }
    }

    func wait(timeout: TimeInterval) -> DispatchTimeoutResult {
        completion.wait(timeout: .now() + timeout)
    }

    func wait() {
        completion.wait()
    }

    var isDelivering: Bool {
        lock.withLock { state == .delivering }
    }

    var wasAccepted: Bool {
        lock.withLock { state == .accepted }
    }
}

final class BrokerOutputDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var nextGeneration: UInt = 0
    private var activeGeneration: UInt?
    private var current: BrokerOutputDeliveryAcceptance?

    func open() -> UInt {
        let result = lock.withLock { () -> (generation: UInt, previous: BrokerOutputDeliveryAcceptance?) in
            nextGeneration &+= 1
            let previous = current
            activeGeneration = nextGeneration
            current = nil
            return (nextGeneration, previous)
        }
        _ = result.previous?.cancelIfPending()
        return result.generation
    }

    func install(_ acceptance: BrokerOutputDeliveryAcceptance, generation: UInt) -> Bool {
        let result = lock.withLock { () -> (installed: Bool, previous: BrokerOutputDeliveryAcceptance?) in
            guard activeGeneration == generation else { return (false, nil) }
            let previous = current
            current = acceptance
            return (true, previous)
        }
        guard result.installed else {
            _ = acceptance.cancelIfPending()
            return false
        }
        _ = result.previous?.cancelIfPending()
        return true
    }

    func remove(_ acceptance: BrokerOutputDeliveryAcceptance) {
        lock.withLock {
            if current === acceptance {
                current = nil
            }
        }
    }

    func close() {
        let acceptance = lock.withLock { () -> BrokerOutputDeliveryAcceptance? in
            activeGeneration = nil
            let acceptance = current
            current = nil
            return acceptance
        }
        _ = acceptance?.cancelIfPending()
    }
}

private enum BrokerOutputDeliveryFailure: Error, CustomStringConvertible {
    case timedOut

    var description: String {
        "Broker output delivery to the terminal timed out"
    }
}

private struct BrokerSessionCompositeFailure: Error, CustomStringConvertible, Sendable {
    let description: String
}

/// Bridges the output lane's exit observation to main-actor publication without
/// leaving a teardown window where both lanes can claim finalization authority.
private final class BrokerExitResolutionClaim: @unchecked Sendable {
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

private final class BrokerOutputReadLane: @unchecked Sendable {
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

    func wake(sessionID: BrokerSessionID) {
        guard isOpen(for: sessionID) else { return }
        lock.withLock { semaphore }?.signal()
    }

    func stop() {
        let semaphore = lock.withLock { () -> DispatchSemaphore? in
            openSessionID = nil
            openRunGeneration = nil
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


    @discardableResult
    private func closeIfCurrent(_ sessionID: BrokerSessionID, runGeneration: UInt) -> Bool {
        lock.withLock {
            if openSessionID == sessionID, openRunGeneration == runGeneration {
                openSessionID = nil
                openRunGeneration = nil
                semaphore?.signal()
                semaphore = nil
                return true
            }
            return false
        }
    }
}

private final class BrokerInputWriteLane: @unchecked Sendable {
    private let queue = DispatchQueue(label: "holoscape.broker.input.write-lane", qos: .userInteractive)
    private let lock = NSLock()
    private var openSessionID: BrokerSessionID?
    private var nextRunGeneration: UInt = 0
    private var openRunGeneration: UInt?

    func open(for sessionID: BrokerSessionID) {
        lock.withLock {
            nextRunGeneration &+= 1
            openSessionID = sessionID
            openRunGeneration = nextRunGeneration
        }
    }

    func close() {
        lock.withLock {
            openSessionID = nil
            openRunGeneration = nil
        }
    }

    func enqueue(
        sessionID: BrokerSessionID,
        bytes: [UInt8],
        write: @escaping @Sendable (BrokerSessionID, [UInt8]) throws -> Void,
        onSuccess: @escaping @Sendable (BrokerSessionID) -> Void,
        onFailure: @escaping @Sendable (BrokerSessionID, Error) -> Void
    ) {
        guard let runGeneration = runGeneration(for: sessionID) else { return }
        queue.async { [weak self] in
            guard let self, self.isOpen(for: sessionID, runGeneration: runGeneration) else { return }
            do {
                try write(sessionID, bytes)
                guard self.isOpen(for: sessionID, runGeneration: runGeneration) else { return }
                onSuccess(sessionID)
            } catch {
                if self.closeIfCurrent(sessionID, runGeneration: runGeneration) {
                    onFailure(sessionID, error)
                }
            }
        }
    }

    private func runGeneration(for sessionID: BrokerSessionID) -> UInt? {
        lock.withLock { openSessionID == sessionID ? openRunGeneration : nil }
    }

    private func isOpen(for sessionID: BrokerSessionID, runGeneration: UInt) -> Bool {
        lock.withLock { openSessionID == sessionID && openRunGeneration == runGeneration }
    }

    @discardableResult
    private func closeIfCurrent(_ sessionID: BrokerSessionID, runGeneration: UInt) -> Bool {
        lock.withLock {
            if openSessionID == sessionID, openRunGeneration == runGeneration {
                openSessionID = nil
                openRunGeneration = nil
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
