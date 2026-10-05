import AppKit
import SwiftTerm

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
    /// Identifies the terminal-view ownership window allowed to consume broker
    /// output. A queued main-actor delivery must still hold this exact lease;
    /// matching the broker ID alone is insufficient because teardown deliberately
    /// preserves that ID for later reattach.
    private var nextOutputDeliveryGeneration: UInt = 0
    private var activeOutputDeliveryGeneration: UInt?
    private let outputReadLane = BrokerOutputReadLane()
    private let inputWriteLane = BrokerInputWriteLane()
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
        coordinator: any BrokerSessionCoordinating = BrokerSessionCoordinator(
            runtime: NativePTYBrokerSessionRuntime(scrollbackDirectory: ScrollbackPersistencePolicy.defaultDiskDirectory)
        ),
        terminalView: HoloscapeTerminalView = HoloscapeTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    ) {
        self.channelID = channelID
        self.channelType = channelType
        self.label = label
        self.environmentProfile = environmentProfile
        self.coordinator = coordinator
        self.inputCoordinator = BrokerInputCoordinator(coordinator)
        self.outputCoordinator = BrokerOutputCoordinator(coordinator)
        self.failureRecoveryCoordinator = BrokerFailureRecoveryCoordinator(coordinator)
        self.terminalView = terminalView
        self.brokerSessionID = existingBrokerSessionID

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
        guard recoveringBrokerSessionID == nil, !startCompletionPending else {
            NSLog("Broker-backed terminal retry ignored while session recovery is still running")
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
        completion: @escaping @MainActor () -> Void
    ) {
        failureRecoveryCoordinator.markErrored(id) { [self] error in
            DispatchQueue.main.async { [self] in
                guard let error else {
                    completion()
                    return
                }
                NSLog("Broker-backed terminal could not retire tracked session \(id.rawValue) during teardown; retrying: \(error)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
                    retireTrackedForTeardown(id, completion: completion)
                }
            }
        }
    }

    private func retireUntrackedForTeardown(
        _ id: BrokerSessionID,
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
                NSLog("Broker-backed terminal could not retire untracked session \(id.rawValue) during teardown; retrying: \(error)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
                    retireUntrackedForTeardown(id, completion: completion)
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

    private func reattachExistingSession(_ sessionID: BrokerSessionID) {
        startFailureDescription = nil
        startFailureKind = nil
        lastScrollbackReplay = nil
        staleBrokerSessionID = nil
        sessionFailure = nil
        let coordinator = self.coordinator
        let channelID = self.channelID
        let shouldReplayScrollback = presentedBrokerSessionID != sessionID
        reattachGeneration &+= 1
        let generation = reattachGeneration
        guard coordinator.requiresOffMainBrokerWork else {
            finishReattach(
                sessionID: sessionID,
                result: Result { try coordinator.reattach(sessionID, attachedChannelID: channelID) },
                replay: nil,
                shouldReplayScrollback: shouldReplayScrollback,
                notifyStartCompletion: false,
                authorityGeneration: generation
            )
            return
        }
        startCompletionPending = true
        failureRecoveryCoordinator.reattach(
            sessionID,
            attachedChannelID: channelID,
            shouldReplayScrollback: shouldReplayScrollback
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.startCompletionPending,
                      self.reattachGeneration == generation,
                      self.brokerSessionID == sessionID else { return }
                self.finishReattach(
                    sessionID: sessionID,
                    result: result.record,
                    replay: result.replay,
                    shouldReplayScrollback: shouldReplayScrollback,
                    notifyStartCompletion: true,
                    authorityGeneration: generation
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
        authorityGeneration: UInt
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
                failureRecoveryCoordinator.acknowledgeOutput(record.id, through: generation) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self,
                              self.reattachGeneration == authorityGeneration,
                              self.brokerSessionID == record.id,
                              self.startCompletionPending else { return }
                        if let error {
                            self.failReattach(error, sessionID: sessionID)
                            self.completeReattachStartIfNeeded(notifyStartCompletion)
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
        let consume: @MainActor @Sendable (Result<BrokerOutputSnapshot, Error>) -> Void = { [weak self] result in
            guard let self,
                  self.brokerSessionID == record.id,
                  self.activeOutputDeliveryGeneration == deliveryGeneration else { return }
            do {
                let snapshot = try result.get()
                self.handleOutputPumpSample(snapshot.data, for: record.id)
                if let generation = snapshot.generation {
                    self.failureRecoveryCoordinator.acknowledgeOutput(record.id, through: generation) { error in
                        DispatchQueue.main.async {
                            guard self.brokerSessionID == record.id,
                                  self.activeOutputDeliveryGeneration == deliveryGeneration else { return }
                            if let error {
                                self.failExitedOutputDelivery(error, notifyStartCompletion: notifyStartCompletion)
                                return
                            }
                            self.drainExitedOutput(
                                record,
                                exitCode: exitCode,
                                deliveryGeneration: deliveryGeneration,
                                notifyStartCompletion: notifyStartCompletion
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
                self.failExitedOutputDelivery(error, notifyStartCompletion: notifyStartCompletion)
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
        let completion: @Sendable (Error?) -> Void = { [weak self] error in
            DispatchQueue.main.async {
                guard let self,
                      self.brokerSessionID == record.id,
                      self.activeOutputDeliveryGeneration == deliveryGeneration else { return }
                let completionWarning = error.flatMap { self.isCompletedRetirementWarning($0) ? $0 : nil }
                if let error, completionWarning == nil {
                    if let mismatchDescription {
                        let combined = BrokerSessionCompositeFailure(
                            description: "\(mismatchDescription); failed to retire completed broker session: \(error)"
                        )
                        self.publishSessionFailure(
                            TerminalSessionFailure(kind: .failed, description: combined.description)
                        )
                        self.failExitedOutputDelivery(combined, notifyStartCompletion: notifyStartCompletion)
                    } else {
                        self.failExitedOutputDelivery(error, notifyStartCompletion: notifyStartCompletion)
                    }
                    return
                }
                self.revokeOutputDeliveryOwnership()
                self.brokerSessionID = nil
                self.agentStatusOwnerToken = nil
                self.completeReattachStartIfNeeded(notifyStartCompletion)
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
                if notifyStartCompletion {
                    publishTermination()
                } else {
                    // Synchronous controller activation calls finishActivation
                    // after startProcess returns. Publish exit on the next main
                    // turn so that final state cannot be overwritten as active.
                    DispatchQueue.main.async(execute: publishTermination)
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

    private func completeReattachStartIfNeeded(_ notifyStartCompletion: Bool) {
        guard notifyStartCompletion else { return }
        startCompletionPending = false
        startCompletionHandler?()
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
        // A host reattach may still be executing off-main. Invalidate its token
        // before detaching so its late result cannot reopen I/O or publish the
        // owning controller as active after teardown.
        reattachGeneration &+= 1
        revokeOutputDeliveryOwnership()
        sessionIOReady = false
        stopOutputPump()
        inputWriteLane.close()
        if freshStartPending {
            freshStartCancelled = true
            // A later teardown (for example a second quit after the first was
            // denied) supersedes any reconnect queued while cleanup was live.
            // Never launch a replacement after termination authority completes.
            restartAfterCancelledFreshStart = nil
            freshStartTeardownCompletions.append(completion)
            return
        }
        startCompletionPending = false
        if let brokerSessionID, !didNotifyTermination {
            if coordinator.requiresOffMainBrokerWork {
                failureRecoveryCoordinator.detach(brokerSessionID) { error in
                    if let error {
                        NSLog("Broker-backed terminal detach failed: \(error)")
                    }
                    DispatchQueue.main.async { completion() }
                }
                return
            }
            do {
                _ = try coordinator.detach(brokerSessionID)
            } catch {
                // Detach runs on tab teardown and again during app termination. A
                // broker host outage — or a broker that already dropped the session —
                // must not trap the app while it is quitting. The durable broker
                // record from `ChannelManager.saveState` is what the next launch
                // reads, so report loudly and leave it reattachable for reconcile.
                NSLog("Broker-backed terminal detach failed: \(error)")
            }
        } else if let untrackedBrokerSessionID {
            retireUntrackedForTeardown(untrackedBrokerSessionID, completion: completion)
            return
        }
        completion()
    }

    func pollOutputOnce() {
        guard sessionIOReady, sessionFailure == nil else { return }
        guard let brokerSessionID else { return }
        guard let deliveryGeneration = activeOutputDeliveryGeneration else { return }
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
            onSample: outputSampleHandler(deliveryGeneration: deliveryGeneration),
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
        let supportsOutputAvailabilityMonitoring = (try? coordinator.supportsOutputAvailabilityMonitoring(brokerSessionID)) == true
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
            onSample: outputSampleHandler(deliveryGeneration: deliveryGeneration),
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

    private func outputSampleHandler(deliveryGeneration: UInt) -> @Sendable (BrokerSessionID, Data) -> Bool {
        return { [weak self] id, data in
            // The serial lane does not perform liveness/exit RPCs until the main
            // actor has consumed this sample, preserving final-byte ordering
            // without making the main actor call the broker.
            let delivered = DispatchSemaphore(value: 0)
            let acceptance = BrokerOutputDeliveryAcceptance()
            DispatchQueue.main.async { [weak self] in
                defer { delivered.signal() }
                guard let self,
                      self.activeOutputDeliveryGeneration == deliveryGeneration,
                      self.brokerSessionID == id,
                      self.sessionIOReady,
                      self.sessionFailure == nil else { return }
                self.handleOutputPumpSample(data, for: id)
                acceptance.accept()
            }
            delivered.wait()
            return acceptance.wasAccepted
        }
    }

    private func outputTerminationHandler(deliveryGeneration: UInt) -> @Sendable (BrokerSessionID, Int32, Error?) -> Void {
        { [weak self] id, exitCode, exitWarning in
            Task { @MainActor [weak self] in
                guard let self,
                      self.brokerSessionID == id,
                      self.activeOutputDeliveryGeneration == deliveryGeneration,
                      !self.didNotifyTermination else { return }
                self.outputReadLane.stop()
                self.sessionIOReady = false
                self.inputWriteLane.close()
                if let exitWarning {
                    self.publishSessionFailure(
                        TerminalSessionFailure(kind: .failed, description: String(describing: exitWarning))
                    )
                }

                let completion: @Sendable (Error?) -> Void = { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self,
                              self.brokerSessionID == id,
                              self.activeOutputDeliveryGeneration == deliveryGeneration,
                              !self.didNotifyTermination else { return }
                        let completionWarning = error.flatMap {
                            self.isCompletedRetirementWarning($0) ? $0 : nil
                        }
                        if let error, completionWarning == nil {
                            self.reportSessionFailure(
                                error,
                                for: id,
                                deliveryGeneration: deliveryGeneration
                            )
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

    private func outputFailureHandler(deliveryGeneration: UInt) -> @Sendable (BrokerSessionID, Error) -> Void {
        { [weak self] id, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
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
        let completion: @Sendable (Error?) -> Void = { [weak self] retirementError in
            DispatchQueue.main.async {
                guard let self,
                      self.brokerSessionID == id,
                      self.activeOutputDeliveryGeneration == deliveryGeneration,
                      !self.didNotifyTermination else { return }
                let completionWarning = retirementError.flatMap {
                    self.isCompletedRetirementWarning($0) ? $0 : nil
                }
                if let retirementError, completionWarning == nil {
                    let combined = BrokerSessionCompositeFailure(
                        description: "\(mismatchError); failed to retire completed broker session: \(retirementError)"
                    )
                    self.reportSessionFailure(
                        combined,
                        for: id,
                        deliveryGeneration: deliveryGeneration
                    )
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

        if kind == .brokerSessionStale, isScrollbackPersistenceFailure(error) {
            beginScrollbackFailureRecovery(error, for: sessionID)
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

    private func beginScrollbackFailureRecovery(_ error: Error, for sessionID: BrokerSessionID) {
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

    private func classifyStartFailure(_ error: Error) -> TerminalStartFailureKind {
        if let coordinatorError = error as? BrokerSessionCoordinator.CoordinatorError {
            switch coordinatorError {
            case .missingSession, .staleSession:
                return .brokerSessionStale
            case .brokerHostUnavailable:
                return .brokerHostUnavailable
            case .retirementRollbackFailed, .detachRollbackFailed, .reattachRollbackFailed,
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
        if case let BrokerSessionHostClientRuntime.ClientError.hostFailure(code, message) = error,
           code == "scrollback-persistence-failed"
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

private final class BrokerOutputDeliveryAcceptance: @unchecked Sendable {
    private let lock = NSLock()
    private var accepted = false

    func accept() {
        lock.withLock { accepted = true }
    }

    var wasAccepted: Bool {
        lock.withLock { accepted }
    }
}

private struct BrokerSessionCompositeFailure: Error, CustomStringConvertible, Sendable {
    let description: String
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
        onSample: @escaping @Sendable (BrokerSessionID, Data) -> Bool,
        onTermination: @escaping @Sendable (BrokerSessionID, Int32, Error?) -> Void,
        onFailure: @escaping @Sendable (BrokerSessionID, Error) -> Void
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
                do {
                    let snapshot = try read(sessionID)
                    guard self.isOpen(for: sessionID, runGeneration: runGeneration) else { return }
                    guard onSample(sessionID, snapshot.data) else {
                        self.closeIfCurrent(sessionID, runGeneration: runGeneration)
                        return
                    }
                    if let generation = snapshot.generation {
                        try acknowledge(sessionID, generation)
                    }
                    guard self.isOpen(for: sessionID, runGeneration: runGeneration) else { return }
                    if let exitCode = try terminationStatus(sessionID) {
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
                        if self.closeIfCurrent(sessionID, runGeneration: runGeneration) {
                            onTermination(sessionID, exitCode, completionWarning)
                        }
                        return
                    }
                } catch {
                    if self.closeIfCurrent(sessionID, runGeneration: runGeneration) {
                        onFailure(sessionID, error)
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
        onSample: @escaping @Sendable (BrokerSessionID, Data) -> Bool,
        onTermination: @escaping @Sendable (BrokerSessionID, Int32, Error?) -> Void,
        onFailure: @escaping @Sendable (BrokerSessionID, Error) -> Void
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
            do {
                guard self.isOpen(for: sessionID, runGeneration: runGeneration) else { return }
                let snapshot = try read(sessionID)
                guard self.isOpen(for: sessionID, runGeneration: runGeneration) else { return }
                guard onSample(sessionID, snapshot.data) else {
                    self.closeIfCurrent(sessionID, runGeneration: runGeneration)
                    return
                }
                if let generation = snapshot.generation {
                    try acknowledge(sessionID, generation)
                }
                guard self.isOpen(for: sessionID, runGeneration: runGeneration) else { return }
                if let exitCode = try terminationStatus(sessionID) {
                    guard try self.drainRemainingOutput(
                        sessionID: sessionID,
                        runGeneration: runGeneration,
                        read: read,
                        acknowledge: acknowledge,
                        onSample: onSample
                    ) else { return }
                    let completionWarning = try finishTermination(sessionID, exitCode)
                    if self.closeIfCurrent(sessionID, runGeneration: runGeneration) {
                        onTermination(sessionID, exitCode, completionWarning)
                    }
                    return
                }
                self.closeIfCurrent(sessionID, runGeneration: runGeneration)
            } catch {
                if self.closeIfCurrent(sessionID, runGeneration: runGeneration) {
                    onFailure(sessionID, error)
                }
            }
        }
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
