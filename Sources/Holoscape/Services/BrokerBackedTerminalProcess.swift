import AppKit
import SwiftTerm

/// TerminalProcess implementation backed by Holoscape's broker runtime instead
/// of SwiftTerm's LocalProcessTerminalView owning the child process directly.
///
/// This is the opt-in bridge for #7168: SwiftTerm remains the renderer, while
/// process input/output/resize flow through BrokerSessionCoordinator and the
/// native PTY runtime behind it.
@MainActor
final class BrokerBackedTerminalProcess: TerminalProcess, AcknowledgedTerminalInput {
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
    private let lifecycle: BrokerTerminalLifecycle
    private let terminalView: HoloscapeTerminalView
    private let outputPresentation: BrokerTerminalOutputPresentation
    private var sessionFailureHandler: ((TerminalSessionFailure) -> Void)?
    private var userInputHandler: ((ArraySlice<UInt8>) -> Void)?
    private var hostCurrentDirectoryHandler: ((String?) -> Void)?
    private var terminationHandler: ((Int32?) -> Void)?
    private var startCompletionHandler: (() -> Void)?
    /// A restored identity is not safe for I/O until reattach and scrollback
    /// replay commit. Keeping this separate from `brokerSessionID` prevents an
    /// installed output handler from draining live bytes ahead of replay.
    private var sessionIOReady = false
    private let outputReadLane = BrokerOutputReadLane()
    private let inputWriteLane = BrokerInputWriteLane()
    private let exitedOutputResolutionClaim = BrokerExitResolutionClaim()
    /// Most recent failure observed while operating the live session. `nil` means
    /// the session is healthy (or has not started yet).
    private(set) var sessionFailure: TerminalSessionFailure?
    var brokerSessionID: BrokerSessionID? { lifecycle.brokerSessionID }
    var agentStatusOwnerToken: String? { lifecycle.agentStatusOwnerToken }
    var staleBrokerSessionID: BrokerSessionID? { lifecycle.staleBrokerSessionID }
    var untrackedBrokerSessionID: BrokerSessionID? { lifecycle.untrackedBrokerSessionID }
    var startFailureDescription: String? { lifecycle.startFailureDescription }
    var startFailureKind: TerminalStartFailureKind? { lifecycle.startFailureKind }
    var pendingExitedOutputRetirement: BrokerExitedOutputRetirement? { lifecycle.pendingExitedOutputRetirement }
    var lastScrollbackReplay: ScrollbackReplay? { outputPresentation.lastScrollbackReplay }
    private lazy var terminalViewDelegate = BrokerBackedTerminalViewDelegate(owner: self)

    var terminalContentView: NSView { terminalView }
    var currentGridSize: TerminalGridSize { terminalView.currentGridSize }
    var brokerOwnedSessionID: BrokerSessionID? { brokerSessionID }
    var completesStartAsynchronously: Bool { lifecycle.startCompletionPending }

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
        let failureRecoveryCoordinator = BrokerFailureRecoveryCoordinator(coordinator)
        self.failureRecoveryCoordinator = failureRecoveryCoordinator
        self.lifecycle = BrokerTerminalLifecycle(
            coordinator: coordinator,
            recovery: failureRecoveryCoordinator,
            teardownRetryDelay: teardownRetryDelay,
            brokerSessionID: existingBrokerSessionID,
            pendingExitedOutputRetirement: pendingExitedOutputRetirement
        )
        self.terminalView = terminalView
        self.outputPresentation = BrokerTerminalOutputPresentation(
            terminalView: terminalView,
            deliveryTimeout: outputDeliveryTimeout
        )

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
        if lifecycle.deferStartIfTeardownOwnsSession(
            host: self,
            reenter: { [weak self] in
                self?.startProcess(
                    executable: executable,
                    args: args,
                    environment: environment,
                    execName: execName,
                    currentDirectory: currentDirectory
                )
            },
            resumeAfterCancelledFreshStart: { [weak self] in
                self?.continueStartProcess(
                    executable: executable,
                    args: args,
                    environment: environment,
                    currentDirectory: currentDirectory
                )
            }
        ) {
            return
        }
        guard lifecycle.recoveringBrokerSessionID == nil, !lifecycle.startCompletionPending,
              !lifecycle.exitedOutputRetirementInFlight else {
            NSLog("Broker-backed terminal retry ignored while session recovery is still running")
            return
        }
        if let pendingExitedOutputRetirement {
            retryExitedOutputRetirement(pendingExitedOutputRetirement)
            return
        }
        if let untrackedBrokerSessionID {
            lifecycle.retireUntrackedBeforeReplacement(untrackedBrokerSessionID, host: self) { [weak self] in
                self?.continueStartProcess(
                    executable: executable,
                    args: args,
                    environment: environment,
                    currentDirectory: currentDirectory
                )
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
        guard lifecycle.recoveringBrokerSessionID == nil, !lifecycle.startCompletionPending,
              !lifecycle.exitedOutputRetirementInFlight else {
            NSLog("Broker-backed terminal cleanup resume ignored while session recovery is still running")
            return
        }
        if let pendingExitedOutputRetirement {
            retryExitedOutputRetirement(pendingExitedOutputRetirement)
            return
        }
        guard let brokerSessionID else { return }
        inputWriteLane.close()
        resetStartAttempt()
        revokeSessionPresentation()
        reattachExistingSession(
            brokerSessionID,
            shouldReplayScrollback: false,
            cleanupOnly: true
        )
    }

    func retryPendingExitedOutputRetirementForCleanup(
        _ pending: BrokerExitedOutputRetirement
    ) {
        retryExitedOutputRetirement(pending, notifyStartCompletion: false)
    }

    private func continueStartProcess(
        executable: String,
        args: [String],
        environment: [String]?,
        currentDirectory: String?
    ) {
        inputWriteLane.close()
        lifecycle.untrackedBrokerSessionID = nil
        resetStartAttempt()
        revokeSessionPresentation()
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
            lifecycle.startCompletionPending = true
            lifecycle.freshStartPending = true
            lifecycle.freshStartCancelled = false
            failureRecoveryCoordinator.start(
                request,
                channelType: channelType,
                label: label,
                attachedChannelID: channelID
            ) { [self] result in
                DispatchQueue.main.async { [self] in
                    guard lifecycle.freshStartPending else { return }
                    if lifecycle.freshStartCancelled {
                        lifecycle.finishCancelledFreshStart(result)
                        return
                    }
                    finishNewSessionStart(result)
                    lifecycle.freshStartPending = false
                    lifecycle.startCompletionPending = false
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
            lifecycle.adopt(record)
            outputPresentation.presentedBrokerSessionID = record.id
            inputWriteLane.open(for: record.id)
            beginOutputDeliveryOwnership()
            sessionIOReady = true
            if outputPresentation.hasOutputHandler {
                startOutputPump()
            }
        } catch {
            let failure = BrokerLaunchFailure(error)
            lifecycle.recordLaunchFailure(failure)
            if case let .registryCommitted(record) = failure {
                outputPresentation.presentedBrokerSessionID = record.id
            }
            revokeSessionPresentation()
            lifecycle.recordStartFailure(error)
            NSLog("Broker-backed terminal start failed: \(error)")
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

    /// Clears the previous attempt's failure and replay before a start or reattach.
    private func resetStartAttempt() {
        lifecycle.clearStartFailure()
        outputPresentation.clearReplay()
        sessionFailure = nil
    }

    private func reattachExistingSession(
        _ sessionID: BrokerSessionID,
        shouldReplayScrollback explicitReplayPolicy: Bool? = nil,
        cleanupOnly: Bool = false
    ) {
        resetStartAttempt()
        let coordinator = self.coordinator
        let channelID = self.channelID
        let shouldReplayScrollback = explicitReplayPolicy ?? (outputPresentation.presentedBrokerSessionID != sessionID)
        lifecycle.reattachGeneration &+= 1
        let generation = lifecycle.reattachGeneration
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
        lifecycle.startCompletionPending = true
        lifecycle.reattachWorkInFlight = true
        failureRecoveryCoordinator.reattach(
            sessionID,
            attachedChannelID: channelID,
            shouldReplayScrollback: shouldReplayScrollback
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lifecycle.reattachWorkInFlight = false
                let waiters = self.lifecycle.reattachWorkCompletionWaiters
                self.lifecycle.reattachWorkCompletionWaiters.removeAll()
                waiters.forEach { $0() }
                guard self.lifecycle.startCompletionPending,
                      self.lifecycle.reattachGeneration == generation,
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
            lifecycle.adopt(record)
            // The durable broker record is authoritative after a delayed retry;
            // publish it through the same host-truth seam as OSC 7 so the owning
            // shell replaces any stale channel metadata before saving again.
            hostCurrentDirectoryHandler?(record.workingDirectory)
            if cleanupOnly, record.lifecycle == .exited {
                guard let exitCode = record.exitCode else {
                    self.lifecycle.startFailureDescription = "Exited broker session \(record.id.rawValue) has no exit code"
                    self.lifecycle.startFailureKind = .failed
                    self.lifecycle.completeReattachStartIfNeeded(notifyStartCompletion, host: self)
                    return
                }
                lifecycle.exitedOutputResolutionInFlight = true
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
                outputPresentation.presentedBrokerSessionID = record.id
            }
            if let generation = replay?.generation {
                if record.lifecycle == .exited {
                    lifecycle.exitedOutputResolutionInFlight = true
                }
                failureRecoveryCoordinator.acknowledgeOutput(record.id, through: generation) { [self] error in
                    DispatchQueue.main.async {
                        guard self.brokerSessionID == record.id else { return }
                        if record.lifecycle != .exited {
                            guard self.lifecycle.reattachGeneration == authorityGeneration,
                                  self.lifecycle.startCompletionPending else { return }
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
                                self.lifecycle.completeReattachStartIfNeeded(notifyStartCompletion, host: self)
                            }
                            return
                        }
                        guard self.lifecycle.reattachGeneration == authorityGeneration,
                              self.lifecycle.startCompletionPending else {
                            if let exitCode = record.exitCode {
                                self.retireExitedSession(
                                    record,
                                    exitCode: exitCode,
                                    deliveryGeneration: self.outputPresentation.activeDeliveryGeneration ?? 0,
                                    notifyStartCompletion: false
                                )
                            } else {
                                self.lifecycle.finishExitedOutputResolution(host: self)
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
            self.lifecycle.completeReattachStartIfNeeded(notifyStartCompletion, host: self)
        }
    }

    private func completeSuccessfulReattach(
        _ record: BrokerSessionRecord,
        notifyStartCompletion: Bool
    ) {
        inputWriteLane.open(for: record.id)
        outputPresentation.presentedBrokerSessionID = record.id
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
            if outputPresentation.hasOutputHandler {
                startOutputPump()
            }
            self.lifecycle.completeReattachStartIfNeeded(notifyStartCompletion, host: self)
            return
        }
        beginOutputDeliveryOwnership()
        sessionIOReady = true
        if outputPresentation.hasOutputHandler {
            startOutputPump()
        }
        self.lifecycle.completeReattachStartIfNeeded(notifyStartCompletion, host: self)
    }

    private func failReattach(_ error: Error, sessionID: BrokerSessionID) {
        lifecycle.recordReattachFailure(error, sessionID: sessionID)
        revokeSessionPresentation()
        NSLog("Broker-backed terminal reattach failed: \(error)")
    }

    private func finishExitedReattach(
        _ record: BrokerSessionRecord,
        notifyStartCompletion: Bool
    ) {
        guard let exitCode = record.exitCode else {
            self.lifecycle.startFailureDescription = "Exited broker session \(record.id.rawValue) has no exit code"
            self.lifecycle.startFailureKind = .failed
            self.lifecycle.completeReattachStartIfNeeded(notifyStartCompletion, host: self)
            return
        }
        guard let deliveryGeneration = outputPresentation.activeDeliveryGeneration else {
            self.lifecycle.completeReattachStartIfNeeded(notifyStartCompletion, host: self)
            return
        }
        lifecycle.exitedOutputResolutionInFlight = true

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
                guard self.outputPresentation.activeDeliveryGeneration == deliveryGeneration else {
                    if lifecycle.preservesUnreadOutputForTermination {
                        // Quit owns a non-consuming detach. The snapshot remains
                        // broker-owned and unacknowledged for replay next launch.
                        self.lifecycle.finishExitedOutputResolution(host: self)
                        return
                    }
                    if let generation = snapshot.generation {
                        lifecycle.startCompletionPending = true
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
                self.outputPresentation.render(snapshot.data)
                if let generation = snapshot.generation {
                    // A nominally synchronous coordinator still acknowledges on
                    // the recovery worker. Delay controller activation until the
                    // acknowledgement and any required retirement are complete.
                    let acknowledgementNotifiesStart = notifyStartCompletion || !lifecycle.startCompletionPending
                    lifecycle.startCompletionPending = true
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
                            guard self.outputPresentation.activeDeliveryGeneration == deliveryGeneration else {
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
        let retirementNotifiesStart = notifyStartCompletion || !lifecycle.startCompletionPending
        lifecycle.startCompletionPending = true
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
                let presentationLeaseIsActive = self.outputPresentation.activeDeliveryGeneration == deliveryGeneration
                let completionWarning = error.flatMap { BrokerTerminalLifecycle.isCompletedRetirementWarning($0) ? $0 : nil }
                if let error, completionWarning == nil {
                    if let mismatchDescription {
                        let combined = BrokerSessionCompositeFailure(
                            description: "\(mismatchDescription); failed to retire completed broker session: \(error)"
                        )
                        self.lifecycle.retainExitedOutputRetirement(
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
                        self.lifecycle.retainExitedOutputRetirement(
                            sessionID: record.id,
                            failureDescription: String(describing: error),
                            failureKind: BrokerTerminalLifecycle.classifyStartFailure(error),
                            observedExitCode: exitCode
                        )
                        self.failExitedOutputDelivery(error, notifyStartCompletion: retirementNotifiesStart)
                    }
                    self.lifecycle.finishExitedOutputResolution(host: self)
                    return
                }
                self.revokeOutputDeliveryOwnership()
                self.lifecycle.clearIdentity()
                self.lifecycle.completeReattachStartIfNeeded(retirementNotifiesStart, host: self)
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
                    guard let self, !lifecycle.didNotifyTermination else { return }
                    lifecycle.didNotifyTermination = true
                    self.terminationHandler?(exitCode)
                }
                if !presentationLeaseIsActive {
                    // Teardown revoked presentation, not lifecycle truth. Publish
                    // the cleared broker identity before releasing the quit
                    // barrier so the controller cannot persist a retired ID.
                    publishTermination()
                    self.lifecycle.finishExitedOutputResolution(host: self)
                } else if retirementNotifiesStart {
                    publishTermination()
                    self.lifecycle.finishExitedOutputResolution(host: self)
                } else {
                    // Synchronous controller activation calls finishActivation
                    // after startProcess returns. Publish exit on the next main
                    // turn so that final state cannot be overwritten as active.
                    DispatchQueue.main.async {
                        publishTermination()
                        self.lifecycle.finishExitedOutputResolution(host: self)
                    }
                }
            }
        }

        lifecycle.retireCompletedSession(record.id, completion: completion)
    }

    private func failExitedOutputDelivery(_ error: Error, notifyStartCompletion: Bool) {
        revokeOutputDeliveryOwnership()
        lifecycle.recordStartFailure(error)
        self.lifecycle.completeReattachStartIfNeeded(notifyStartCompletion, host: self)
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
            outputFailureKind: BrokerTerminalLifecycle.classifyStartFailure(outputError),
            observedExitCode: observedExitCode
        )
        self.lifecycle.pendingExitedOutputRetirement = pending
        lifecycle.exitedOutputRetirementInFlight = true

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

    private func retryExitedOutputRetirement(
        _ pending: BrokerExitedOutputRetirement,
        notifyStartCompletion: Bool = true
    ) {
        if notifyStartCompletion {
            lifecycle.startCompletionPending = true
        }
        lifecycle.exitedOutputRetirementInFlight = true
        lifecycle.exitedOutputResolutionInFlight = true
        failureRecoveryCoordinator.retireCompletedSession(pending.sessionID) { [self] retirementError in
            DispatchQueue.main.async {
                self.finishExitedOutputRetirement(
                    pending,
                    retirementError: retirementError,
                    notifyStartCompletion: notifyStartCompletion
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
        lifecycle.exitedOutputRetirementInFlight = false
        // Teardown suppresses the ordinary activation completion while this
        // cleanup owns the exited session. The controller still needs one final
        // ownership publication before quit persists state: success clears the
        // retired ID, while cleanup failure keeps the retryable ID authoritative.
        let teardownSuppressedStartCompletion = !lifecycle.exitedOutputTeardownCompletions.isEmpty
            && !lifecycle.startCompletionPending

        let completionWarning = retirementError.flatMap {
            BrokerTerminalLifecycle.isCompletedRetirementWarning($0) ? $0 : nil
        }
        if let retirementError, completionWarning == nil {
            self.lifecycle.startFailureDescription = "\(pending.outputFailureDescription); failed to retire completed broker session: \(retirementError)"
            self.lifecycle.startFailureKind = .failed
        } else {
            if let completionWarning {
                self.lifecycle.startFailureDescription = "\(pending.outputFailureDescription); broker retirement completed with warning: \(completionWarning)"
                self.lifecycle.startFailureKind = .failed
            } else {
                self.lifecycle.startFailureDescription = pending.outputFailureDescription
                self.lifecycle.startFailureKind = pending.outputFailureKind
            }
            self.lifecycle.pendingExitedOutputRetirement = nil
            self.lifecycle.clearIdentity()
        }
        revokeOutputDeliveryOwnership()
        sessionIOReady = false
        let publishedFailure = TerminalSessionFailure(
            kind: startFailureKind ?? pending.outputFailureKind,
            description: startFailureDescription ?? pending.outputFailureDescription
        )
        publishSessionFailure(publishedFailure)
        if let exitCode = pending.observedExitCode, !lifecycle.didNotifyTermination {
            lifecycle.didNotifyTermination = true
            terminationHandler?(exitCode)
        }
        self.lifecycle.completeReattachStartIfNeeded(notifyStartCompletion, host: self)
        if teardownSuppressedStartCompletion {
            startCompletionHandler?()
        }
        self.lifecycle.finishExitedOutputResolution(host: self)
    }

    private func restoreScrollbackReplay(for sessionID: BrokerSessionID) {
        do {
            let replay = try coordinator.readScrollbackReplay(
                sessionID,
                maxBytes: ScrollbackPersistencePolicy.maxReplayBytesOnReattach
            )
            outputPresentation.presentReplay(replay)
        } catch {
            // Scrollback corruption must not turn a successfully reattached live
            // process into a stale tab. Surface the recovery plainly in the
            // terminal, then continue with live output from the broker.
            outputPresentation.presentReplayFailure(String(describing: error), sessionID: sessionID)
        }
    }

    private func applyScrollbackReplay(_ result: ScrollbackReplayResult, for sessionID: BrokerSessionID) {
        if let replay = result.replay {
            outputPresentation.presentReplay(replay)
        } else if let error = result.error {
            outputPresentation.presentReplayFailure(error, sessionID: sessionID)
        }
    }

    func send(_ bytes: [UInt8]) {
        send(bytes) { _ in }
    }

    func send(
        _ bytes: [UInt8],
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard let brokerSessionID else {
            // Keystrokes can still reach the view of a stale or disconnected tab.
            // There is no live session to write to, and that is not a broker host
            // outage, so log and ignore rather than trapping the app.
            NSLog("Broker-backed terminal input ignored: no live broker session")
            completion(false)
            return
        }
        guard sessionFailure == nil else {
            // The outage (or dropped session) was already reported to the tab,
            // which is showing its recovery guidance; late keystrokes are inert.
            completion(false)
            return
        }
        guard let deliveryGeneration = outputPresentation.activeDeliveryGeneration else {
            completion(false)
            return
        }
        let accepted = inputWriteLane.enqueue(
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
                Task { @MainActor in completion(true) }
            },
            onFailure: { [weak self] id, error in
                Task { @MainActor [weak self] in
                    self?.reportSessionFailure(error, for: id, deliveryGeneration: deliveryGeneration)
                    completion(false)
                }
            },
            onCancellation: { _ in
                Task { @MainActor in completion(false) }
            }
        )
        if !accepted {
            completion(false)
        }
    }

    func setOutputHandler(_ handler: (() -> Void)?) {
        outputPresentation.setOutputHandler(handler)
        if handler == nil {
            pauseOutputPump()
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

    func detachBrokerSession(
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    ) {
        lifecycle.detachForTeardown(host: self, completion: completion)
    }

    func detachBrokerSessionForCleanup(
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    ) {
        lifecycle.detachForTeardown(host: self, completion: completion)
    }

    func detachBrokerSessionPreservingOutput(
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    ) {
        lifecycle.detachPreservingOutput(host: self, completion: completion)
    }

    func retireBrokerSessionForClose(
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    ) {
        lifecycle.retireForClose(host: self, completion: completion)
    }

    func pollOutputOnce() {
        guard sessionIOReady, sessionFailure == nil else { return }
        guard let brokerSessionID else { return }
        guard let deliveryGeneration = outputPresentation.activeDeliveryGeneration else { return }
        let handoffGeneration = outputPresentation.activeHandoffGeneration ?? beginOutputHandoff()
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
        guard let deliveryGeneration = outputPresentation.activeDeliveryGeneration else { return }
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
        guard let deliveryGeneration = outputPresentation.activeDeliveryGeneration else { return }
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

    private func outputSampleHandler(
        deliveryGeneration: UInt,
        handoffGeneration: UInt
    ) -> @Sendable (BrokerSessionID, Data) -> Bool {
        outputPresentation.makeSampleHandler(
            deliveryGeneration: deliveryGeneration,
            handoffGeneration: handoffGeneration,
            isAuthorized: { [weak self] id in
                guard let self else { return false }
                return self.brokerSessionID == id
                    && self.sessionIOReady
                    && self.sessionFailure == nil
            },
            onFailure: { [weak self] id, error in
                self?.reportSessionFailure(
                    error,
                    for: id,
                    deliveryGeneration: deliveryGeneration
                )
            }
        )
    }

    private func outputTerminationHandler(deliveryGeneration: UInt) -> @Sendable (BrokerSessionID, Int32, Error?) -> Void {
        { [weak self] id, exitCode, exitWarning in
            Task { @MainActor [weak self] in
                guard let self,
                      self.exitedOutputResolutionClaim.consume(for: id) else { return }
                guard self.brokerSessionID == id, !lifecycle.didNotifyTermination else {
                    if lifecycle.exitedOutputResolutionInFlight {
                        self.lifecycle.finishExitedOutputResolution(host: self)
                    }
                    return
                }
                lifecycle.exitedOutputResolutionInFlight = true
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
                              self.lifecycle.exitedOutputResolutionInFlight,
                              !self.lifecycle.didNotifyTermination else { return }
                        let completionWarning = error.flatMap {
                            BrokerTerminalLifecycle.isCompletedRetirementWarning($0) ? $0 : nil
                        }
                        if let error, completionWarning == nil {
                            let failureDescription = exitWarningDescription.map {
                                "\($0); failed to retire completed broker session: \(error)"
                            } ?? String(describing: error)
                            self.lifecycle.retainExitedOutputRetirement(
                                sessionID: id,
                                failureDescription: failureDescription,
                                failureKind: BrokerTerminalLifecycle.classifyStartFailure(error),
                                observedExitCode: exitCode
                            )
                            self.reportSessionFailure(
                                BrokerSessionCompositeFailure(description: failureDescription),
                                for: id,
                                deliveryGeneration: deliveryGeneration
                            )
                            self.lifecycle.didNotifyTermination = true
                            self.terminationHandler?(exitCode)
                            self.lifecycle.finishExitedOutputResolution(host: self)
                            return
                        }
                        self.lifecycle.didNotifyTermination = true
                        self.revokeOutputDeliveryOwnership()
                        self.lifecycle.clearIdentity()
                        if let completionWarning,
                           self.sessionFailure == nil || BrokerTerminalLifecycle.isCompletedOutputRetirementWarning(completionWarning) {
                            self.publishSessionFailure(
                                TerminalSessionFailure(
                                    kind: .failed,
                                    description: String(describing: completionWarning)
                                )
                            )
                        }
                        self.terminationHandler?(exitCode)
                        self.lifecycle.finishExitedOutputResolution(host: self)
                    }
                }

                // Durable exit was already published by the output lane. Remove
                // the retained runtime object before releasing the tab's broker
                // identity; otherwise closing the disconnected tab can make the
                // completed generation appear as a recovered session next launch.
                self.lifecycle.retireCompletedSession(id, completion: completion)
            }
        }
    }

    private func teardownOutputTerminationHandler() -> @Sendable (BrokerSessionID, Int32, Error?) -> Void {
        { [weak self] id, exitCode, exitWarning in
            Task { @MainActor [weak self] in
                guard let self,
                      self.brokerSessionID == id,
                      lifecycle.exitedOutputResolutionInFlight,
                      !lifecycle.didNotifyTermination else { return }
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
                              self.lifecycle.exitedOutputResolutionInFlight,
                              !self.lifecycle.didNotifyTermination else { return }
                        let completionWarning = error.flatMap {
                            BrokerTerminalLifecycle.isCompletedRetirementWarning($0) ? $0 : nil
                        }
                        if let error, completionWarning == nil {
                            let failureDescription = exitWarningDescription.map {
                                "\($0); failed to retire completed broker session: \(error)"
                            } ?? String(describing: error)
                            self.lifecycle.retainExitedOutputRetirement(
                                sessionID: id,
                                failureDescription: failureDescription,
                                failureKind: BrokerTerminalLifecycle.classifyStartFailure(error),
                                observedExitCode: exitCode
                            )
                            self.publishSessionFailure(
                                TerminalSessionFailure(
                                    kind: BrokerTerminalLifecycle.classifyStartFailure(error),
                                    description: failureDescription
                                )
                            )
                            self.lifecycle.didNotifyTermination = true
                            self.terminationHandler?(exitCode)
                            self.lifecycle.finishExitedOutputResolution(host: self)
                            return
                        }
                        self.lifecycle.didNotifyTermination = true
                        self.revokeOutputDeliveryOwnership()
                        self.lifecycle.clearIdentity()
                        if let completionWarning,
                           self.sessionFailure == nil || BrokerTerminalLifecycle.isCompletedOutputRetirementWarning(completionWarning) {
                            self.publishSessionFailure(
                                TerminalSessionFailure(
                                    kind: .failed,
                                    description: String(describing: completionWarning)
                                )
                            )
                        }
                        self.terminationHandler?(exitCode)
                        self.lifecycle.finishExitedOutputResolution(host: self)
                    }
                }

                self.lifecycle.retireCompletedSession(id, completion: completion)
            }
        }
    }

    private func outputFailureHandler(deliveryGeneration: UInt) -> @Sendable (BrokerSessionID, Int32?, Error, Data?) -> Void {
        { [weak self] id, observedExitCode, error, presentedUnacknowledgedData in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let presentedUnacknowledgedData, !presentedUnacknowledgedData.isEmpty {
                    self.outputPresentation.retainPresentedUnacknowledgedOutput(
                        presentedUnacknowledgedData,
                        for: id
                    )
                }
                if self.exitedOutputResolutionClaim.consume(for: id) {
                    guard self.brokerSessionID == id, !lifecycle.didNotifyTermination else {
                        if lifecycle.exitedOutputResolutionInFlight {
                            self.lifecycle.finishExitedOutputResolution(host: self)
                        }
                        return
                    }
                    lifecycle.exitedOutputResolutionInFlight = true
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
                if BrokerTerminalLifecycle.isCompletedExitWarning(error) {
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

    private func retireMismatchedExitedSession(
        _ id: BrokerSessionID,
        observedExitCode: Int32,
        mismatchError: Error,
        deliveryGeneration: UInt
    ) {
        lifecycle.exitedOutputResolutionInFlight = true
        lifecycle.exitedOutputRetirementInFlight = true
        let completion: @Sendable (Error?) -> Void = { [weak self] retirementError in
            DispatchQueue.main.async {
                guard let self,
                      self.brokerSessionID == id,
                      self.lifecycle.exitedOutputResolutionInFlight,
                      !self.lifecycle.didNotifyTermination else { return }
                self.lifecycle.exitedOutputRetirementInFlight = false
                let completionWarning = retirementError.flatMap {
                    BrokerTerminalLifecycle.isCompletedRetirementWarning($0) ? $0 : nil
                }
                if let retirementError, completionWarning == nil {
                    let combined = BrokerSessionCompositeFailure(
                        description: "\(mismatchError); failed to retire completed broker session: \(retirementError)"
                    )
                    self.lifecycle.retainExitedOutputRetirement(
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
                    self.lifecycle.didNotifyTermination = true
                    self.terminationHandler?(observedExitCode)
                    self.lifecycle.finishExitedOutputResolution(host: self)
                    return
                }
                self.lifecycle.didNotifyTermination = true
                self.revokeOutputDeliveryOwnership()
                self.lifecycle.clearIdentity()
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
                self.lifecycle.finishExitedOutputResolution(host: self)
            }
        }

        lifecycle.retireCompletedSession(id, completion: completion)
    }

    func pauseOutputPump() {
        outputPresentation.stopHandoff()
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
              outputPresentation.activeDeliveryGeneration == deliveryGeneration else {
            NSLog("Ignoring delayed broker failure for inactive session \(sessionID.rawValue): \(error)")
            return
        }
        let kind = BrokerTerminalLifecycle.classifyStartFailure(error)
        let description = String(describing: error)
        inputWriteLane.close()
        lifecycle.stopOutputPumpAfterSessionFailure(host: self)
        revokeOutputDeliveryOwnership()

        if kind == .brokerSessionStale,
           BrokerTerminalLifecycle.isScrollbackPersistenceFailure(error) || BrokerTerminalLifecycle.isOutputMonitoringFailure(error) {
            lifecycle.beginOutputFailureRecovery(error, for: sessionID, host: self)
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
            lifecycle.markStale(sessionID)
            sessionIOReady = false
        }

        publishSessionFailure(TerminalSessionFailure(kind: kind, description: description))
    }

    func publishSessionFailure(_ failure: TerminalSessionFailure) {
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
        outputPresentation.beginDeliveryOwnership()
    }

    private func revokeOutputDeliveryOwnership() {
        outputPresentation.revokeDeliveryOwnership()
    }

    private func beginOutputHandoff() -> UInt {
        outputPresentation.beginHandoff()
    }
}

extension BrokerBackedTerminalProcess: BrokerTerminalLifecycleHost {
    func closeInputWrites() {
        inputWriteLane.close()
    }

    func markSessionIONotReady() {
        sessionIOReady = false
    }

    func revokeSessionPresentation() {
        revokeOutputDeliveryOwnership()
        sessionIOReady = false
    }

    func clearOutputAvailabilityHandler(for id: BrokerSessionID) -> Error? {
        do {
            try coordinator.setOutputAvailabilityHandler(id, handler: nil)
            return nil
        } catch {
            return error
        }
    }

    func finishOutputLaneWithoutConsuming(_ completion: @escaping @Sendable () -> Void) {
        outputReadLane.finishWithoutConsuming(completion: completion)
    }

    func finishOutputLaneForClose(_ completion: @escaping @Sendable () -> Void) {
        outputReadLane.finishForClose(completion: completion)
    }

    func joinClaimedExitResolution(for id: BrokerSessionID) -> Bool {
        exitedOutputResolutionClaim.joinOrStop(id, stop: { [outputReadLane] in outputReadLane.stop() })
    }

    var canProbeRunningSessionAtTeardown: Bool {
        sessionIOReady && outputPresentation.activeDeliveryGeneration != nil
    }

    /// Quiesce ordinary reads before probing on the same serial lane. A
    /// running child remains non-consuming and detaches normally. A child
    /// that already stopped is drained, acknowledged, finalized, and retired
    /// before teardown releases its cleanup owner.
    func beginRunningSessionTeardownProbe(for id: BrokerSessionID) {
        outputReadLane.finishForTeardown(
            sessionID: id,
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
                    guard let self else { return }
                    self.lifecycle.finishRunningSessionTeardownProbe(host: self, error: error)
                }
            }
        )
    }

    func publishStartCompletion() {
        startCompletionHandler?()
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

fileprivate struct ScrollbackReplayResult: Sendable {
    let replay: ScrollbackReplay?
    let generation: UInt64?
    let error: String?
}

fileprivate struct ReattachResult: Sendable {
    let record: Result<BrokerSessionRecord, Error>
    let replay: ScrollbackReplayResult?
}

final class BrokerFailureRecoveryCoordinator: @unchecked Sendable {
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

    fileprivate func reattach(
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

    @discardableResult
    func enqueue(
        sessionID: BrokerSessionID,
        bytes: [UInt8],
        write: @escaping @Sendable (BrokerSessionID, [UInt8]) throws -> Void,
        onSuccess: @escaping @Sendable (BrokerSessionID) -> Void,
        onFailure: @escaping @Sendable (BrokerSessionID, Error) -> Void,
        onCancellation: @escaping @Sendable (BrokerSessionID) -> Void
    ) -> Bool {
        guard let runGeneration = runGeneration(for: sessionID) else { return false }
        queue.async { [weak self] in
            guard let self else {
                onCancellation(sessionID)
                return
            }
            guard self.isOpen(for: sessionID, runGeneration: runGeneration) else {
                onCancellation(sessionID)
                return
            }
            do {
                try write(sessionID, bytes)
                guard self.isOpen(for: sessionID, runGeneration: runGeneration) else {
                    onCancellation(sessionID)
                    return
                }
                onSuccess(sessionID)
            } catch {
                if self.closeIfCurrent(sessionID, runGeneration: runGeneration) {
                    onFailure(sessionID, error)
                } else {
                    onCancellation(sessionID)
                }
            }
        }
        return true
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
