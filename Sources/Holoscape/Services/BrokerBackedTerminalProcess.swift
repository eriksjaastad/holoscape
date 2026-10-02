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
    private var freshStartPending = false
    private var freshStartCancelled = false
    private var freshStartTeardownCompletions: [@MainActor () -> Void] = []
    private var reattachGeneration: UInt = 0
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
                    } else {
                        self.untrackedBrokerSessionID = nil
                        self.continueStartProcess(
                            executable: executable,
                            args: args,
                            environment: environment,
                            currentDirectory: currentDirectory
                        )
                    }
                    self.startCompletionPending = false
                    self.startCompletionHandler?()
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
            agentStatusOwnerToken = record.agentStatusOwnerToken
            didNotifyTermination = false
            inputWriteLane.open(for: record.id)
            if outputHandler != nil {
                startOutputPump()
            }
        } catch {
            if case let BrokerSessionCoordinator.CoordinatorError.untrackedSession(id, _, _) = error {
                untrackedBrokerSessionID = id
            }
            brokerSessionID = nil
            agentStatusOwnerToken = nil
            startFailureDescription = String(describing: error)
            startFailureKind = classifyStartFailure(error)
            NSLog("Broker-backed terminal start failed: \(error)")
        }
    }

    private func finishCancelledFreshStart(_ result: Result<BrokerSessionRecord, Error>) {
        switch result {
        case .success(let record):
            failureRecoveryCoordinator.markErrored(record.id) { [self] error in
                DispatchQueue.main.async { [self] in
                    if let error {
                        NSLog("Broker-backed terminal could not retire cancelled fresh session \(record.id.rawValue): \(error)")
                    }
                    completeCancelledFreshStart()
                }
            }
        case .failure(let error):
            if case let BrokerSessionCoordinator.CoordinatorError.untrackedSession(id, _, _) = error {
                failureRecoveryCoordinator.retireUntrackedSession(id) { [self] retirementError in
                    DispatchQueue.main.async { [self] in
                        if let retirementError {
                            NSLog("Broker-backed terminal could not retire cancelled untracked session \(id.rawValue): \(retirementError)")
                        }
                        completeCancelledFreshStart()
                    }
                }
            } else {
                completeCancelledFreshStart()
            }
        }
    }

    private func completeCancelledFreshStart() {
        freshStartPending = false
        freshStartCancelled = false
        startCompletionPending = false
        let completions = freshStartTeardownCompletions
        freshStartTeardownCompletions.removeAll()
        completions.forEach { $0() }
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
        guard coordinator.requiresOffMainBrokerWork else {
            finishReattach(
                sessionID: sessionID,
                result: Result { try coordinator.reattach(sessionID, attachedChannelID: channelID) },
                replay: nil,
                notifyStartCompletion: false
            )
            return
        }
        startCompletionPending = true
        reattachGeneration &+= 1
        let generation = reattachGeneration
        failureRecoveryCoordinator.reattach(sessionID, attachedChannelID: channelID) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.startCompletionPending,
                      self.reattachGeneration == generation,
                      self.brokerSessionID == sessionID else { return }
                self.finishReattach(
                    sessionID: sessionID,
                    result: result.record,
                    replay: result.replay,
                    notifyStartCompletion: true
                )
            }
        }
    }

    private func finishReattach(
        sessionID: BrokerSessionID,
        result: Result<BrokerSessionRecord, Error>,
        replay: ScrollbackReplayResult?,
        notifyStartCompletion: Bool
    ) {
        do {
            let record = try result.get()
            brokerSessionID = record.id
            agentStatusOwnerToken = record.agentStatusOwnerToken
            didNotifyTermination = false
            inputWriteLane.open(for: record.id)
            // The durable broker record is authoritative after a delayed retry;
            // publish it through the same host-truth seam as OSC 7 so the owning
            // shell replaces any stale channel metadata before saving again.
            hostCurrentDirectoryHandler?(record.workingDirectory)
            if let replay {
                applyScrollbackReplay(replay, for: record.id)
            } else {
                restoreScrollbackReplay(for: record.id)
            }
            if outputHandler != nil {
                startOutputPump()
            }
        } catch {
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
            NSLog("Broker-backed terminal reattach failed: \(error)")
        }
        if notifyStartCompletion {
            startCompletionPending = false
            startCompletionHandler?()
        }
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
                    self?.reportSessionFailure(error, for: id)
                }
            }
        )
    }

    func setOutputHandler(_ handler: (() -> Void)?) {
        outputHandler = handler
        if handler == nil {
            stopOutputPump()
        } else if brokerSessionID != nil, sessionFailure == nil {
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
        stopOutputPump()
        inputWriteLane.close()
        if freshStartPending {
            freshStartCancelled = true
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
            if coordinator.requiresOffMainBrokerWork {
                failureRecoveryCoordinator.retireUntrackedSession(untrackedBrokerSessionID) { [weak self] error in
                    DispatchQueue.main.async { [weak self] in
                        if let self, self.untrackedBrokerSessionID == untrackedBrokerSessionID {
                            if let error {
                                NSLog("Broker-backed terminal could not retire untracked session \(untrackedBrokerSessionID.rawValue) during teardown: \(error)")
                            } else {
                                self.untrackedBrokerSessionID = nil
                            }
                        }
                        completion()
                    }
                }
                return
            }
            do {
                try coordinator.retireUntrackedSession(untrackedBrokerSessionID)
                self.untrackedBrokerSessionID = nil
            } catch {
                NSLog("Broker-backed terminal could not retire untracked session \(untrackedBrokerSessionID.rawValue) during teardown: \(error)")
            }
        }
        completion()
    }

    func pollOutputOnce() {
        guard sessionFailure == nil else { return }
        guard let brokerSessionID else { return }
        outputReadLane.pollOnce(
            sessionID: brokerSessionID,
            read: { [outputCoordinator] id in
                try outputCoordinator.readAvailableOutput(id)
            },
            afterDelivery: { [outputCoordinator] id in
                try outputCoordinator.finishTerminationIfNeeded(id)
            },
            onSample: outputSampleHandler(),
            onTermination: outputTerminationHandler(),
            onFailure: outputFailureHandler()
        )
    }

    func resizeToCurrentGrid() {
        guard sessionFailure == nil else { return }
        guard let brokerSessionID else {
            NSLog("Broker-backed terminal resize ignored: no live broker session")
            return
        }
        do {
            try coordinator.resize(brokerSessionID, size: currentGridSize)
        } catch {
            reportSessionFailure(error, for: brokerSessionID)
        }
    }

    fileprivate func terminalViewDidResize() {
        resizeToCurrentGrid()
    }

    fileprivate func terminalViewDidUpdateHostCurrentDirectory(_ directory: String?) {
        hostCurrentDirectoryHandler?(directory)
    }

    private func startOutputPump() {
        guard let brokerSessionID else { return }
        let supportsOutputAvailabilityMonitoring = (try? coordinator.supportsOutputAvailabilityMonitoring(brokerSessionID)) == true
        outputReadLane.start(
            sessionID: brokerSessionID,
            mode: supportsOutputAvailabilityMonitoring ? .outputAvailabilitySignal : .periodicPolling,
            read: { [outputCoordinator] id in
                try outputCoordinator.readAvailableOutput(id)
            },
            afterDelivery: { [outputCoordinator] id in
                try outputCoordinator.finishTerminationIfNeeded(id)
            },
            onSample: outputSampleHandler(),
            onTermination: outputTerminationHandler(),
            onFailure: outputFailureHandler()
        )
        do {
            try coordinator.setOutputAvailabilityHandler(brokerSessionID) { [outputReadLane] id in
                outputReadLane.wake(sessionID: id)
            }
        } catch {
            reportSessionFailure(error, for: brokerSessionID)
        }
    }

    private func handleOutputPumpSample(_ data: Data, for brokerSessionID: BrokerSessionID) {
        if !data.isEmpty {
            let bytes = Array(data)
            terminalView.feed(byteArray: bytes[...])
            outputHandler?()
        }
    }

    private func outputSampleHandler() -> @Sendable (BrokerSessionID, Data) -> Void {
        { [weak self] id, data in
            // The serial lane does not perform liveness/exit RPCs until the main
            // actor has consumed this sample, preserving final-byte ordering
            // without making the main actor call the broker.
            let delivered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { [weak self] in
                defer { delivered.signal() }
                guard let self, self.brokerSessionID == id, self.sessionFailure == nil else { return }
                self.handleOutputPumpSample(data, for: id)
            }
            delivered.wait()
        }
    }

    private func outputTerminationHandler() -> @Sendable (BrokerSessionID, Int32) -> Void {
        { [weak self] id, exitCode in
            Task { @MainActor [weak self] in
                guard let self,
                      self.brokerSessionID == id,
                      !self.didNotifyTermination else { return }
                self.didNotifyTermination = true
                self.outputReadLane.stop()
                self.brokerSessionID = nil
                self.agentStatusOwnerToken = nil
                self.terminationHandler?(exitCode)
            }
        }
    }

    private func outputFailureHandler() -> @Sendable (BrokerSessionID, Error) -> Void {
        { [weak self] id, error in
            Task { @MainActor [weak self] in
                self?.reportSessionFailure(error, for: id)
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
    private func reportSessionFailure(_ error: Error, for sessionID: BrokerSessionID) {
        guard brokerSessionID == sessionID else {
            NSLog("Ignoring delayed broker failure for inactive session \(sessionID.rawValue): \(error)")
            return
        }
        let kind = classifyStartFailure(error)
        let description = String(describing: error)
        inputWriteLane.close()
        stopOutputPump()

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

                if let recoveryError {
                    self.publishSessionFailure(
                        TerminalSessionFailure(
                            kind: .failed,
                            description: originalDescription
                                + "; failed to retire persistence-broken broker session: \(recoveryError)"
                        )
                    )
                } else {
                    self.brokerSessionID = nil
                    self.staleBrokerSessionID = sessionID
                    self.publishSessionFailure(
                        TerminalSessionFailure(kind: .brokerSessionStale, description: originalDescription)
                    )
                }
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
            case .retirementRollbackFailed, .detachRollbackFailed, .reattachRollbackFailed, .reattachCleanupFailed:
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

    func readAvailableOutput(_ id: BrokerSessionID) throws -> Data {
        try coordinator.readAvailableOutput(id)
    }

    /// Check and durably finalize process exit on the same serial lane as output
    /// reads. The lane calls this only after SwiftTerm has consumed the preceding
    /// sample, so final bytes remain visible before exit becomes authoritative.
    func finishTerminationIfNeeded(_ id: BrokerSessionID) throws -> Int32? {
        guard try !coordinator.isRunning(id) else { return nil }
        guard let exitCode = try coordinator.terminationStatus(id) else {
            // Final PTY bytes or their persistence result are still in flight.
            return nil
        }
        _ = try coordinator.exit(id, exitCode: exitCode)
        return exitCode
    }
}

private struct ScrollbackReplayResult: Sendable {
    let replay: ScrollbackReplay?
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
        completion: @escaping @Sendable (ReattachResult) -> Void
    ) {
        queue.async { [self] in
            do {
                let record = try coordinator.reattach(id, attachedChannelID: attachedChannelID)
                let replay: ScrollbackReplayResult
                do {
                    replay = ScrollbackReplayResult(
                        replay: try coordinator.readScrollbackReplay(id, maxBytes: ScrollbackPersistencePolicy.maxReplayBytesOnReattach),
                        error: nil
                    )
                } catch {
                    replay = ScrollbackReplayResult(replay: nil, error: String(describing: error))
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
    private var semaphore: DispatchSemaphore?

    init(signalTerminationCheckInterval: TimeInterval = 1.0, pollingInterval: TimeInterval = 0.02) {
        self.signalTerminationCheckInterval = signalTerminationCheckInterval
        self.pollingInterval = pollingInterval
    }

    func start(
        sessionID: BrokerSessionID,
        mode: Mode,
        read: @escaping @Sendable (BrokerSessionID) throws -> Data,
        afterDelivery: @escaping @Sendable (BrokerSessionID) throws -> Int32?,
        onSample: @escaping @Sendable (BrokerSessionID, Data) -> Void,
        onTermination: @escaping @Sendable (BrokerSessionID, Int32) -> Void,
        onFailure: @escaping @Sendable (BrokerSessionID, Error) -> Void
    ) {
        stop()
        let semaphore = DispatchSemaphore(value: 0)
        lock.withLock {
            openSessionID = sessionID
            self.semaphore = semaphore
        }

        queue.async { [weak self] in
            semaphore.signal()
            while true {
                guard let self, self.isOpen(for: sessionID) else { return }
                switch mode {
                case .outputAvailabilitySignal:
                    _ = semaphore.wait(timeout: .now() + self.signalTerminationCheckInterval)
                case .periodicPolling:
                    _ = semaphore.wait(timeout: .now() + self.pollingInterval)
                }
                guard self.isOpen(for: sessionID) else { return }
                do {
                    let data = try read(sessionID)
                    guard self.isOpen(for: sessionID) else { return }
                    onSample(sessionID, data)
                    guard self.isOpen(for: sessionID) else { return }
                    if let exitCode = try afterDelivery(sessionID) {
                        self.closeIfCurrent(sessionID)
                        onTermination(sessionID, exitCode)
                        return
                    }
                } catch {
                    self.closeIfCurrent(sessionID)
                    onFailure(sessionID, error)
                    return
                }
            }
        }
    }

    func pollOnce(
        sessionID: BrokerSessionID,
        read: @escaping @Sendable (BrokerSessionID) throws -> Data,
        afterDelivery: @escaping @Sendable (BrokerSessionID) throws -> Int32?,
        onSample: @escaping @Sendable (BrokerSessionID, Data) -> Void,
        onTermination: @escaping @Sendable (BrokerSessionID, Int32) -> Void,
        onFailure: @escaping @Sendable (BrokerSessionID, Error) -> Void
    ) {
        if isOpen(for: sessionID) {
            wake(sessionID: sessionID)
            return
        }
        queue.async {
            do {
                let data = try read(sessionID)
                onSample(sessionID, data)
                if let exitCode = try afterDelivery(sessionID) {
                    onTermination(sessionID, exitCode)
                }
            } catch {
                onFailure(sessionID, error)
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
            let current = self.semaphore
            self.semaphore = nil
            return current
        }
        semaphore?.signal()
    }

    private func isOpen(for sessionID: BrokerSessionID) -> Bool {
        lock.withLock { openSessionID == sessionID }
    }

    private func closeIfCurrent(_ sessionID: BrokerSessionID) {
        lock.withLock {
            if openSessionID == sessionID {
                openSessionID = nil
                semaphore?.signal()
                semaphore = nil
            }
        }
    }
}

private final class BrokerInputWriteLane: @unchecked Sendable {
    private let queue = DispatchQueue(label: "holoscape.broker.input.write-lane", qos: .userInteractive)
    private let lock = NSLock()
    private var openSessionID: BrokerSessionID?

    func open(for sessionID: BrokerSessionID) {
        lock.withLock {
            openSessionID = sessionID
        }
    }

    func close() {
        lock.withLock {
            openSessionID = nil
        }
    }

    func enqueue(
        sessionID: BrokerSessionID,
        bytes: [UInt8],
        write: @escaping @Sendable (BrokerSessionID, [UInt8]) throws -> Void,
        onSuccess: @escaping @Sendable (BrokerSessionID) -> Void,
        onFailure: @escaping @Sendable (BrokerSessionID, Error) -> Void
    ) {
        guard isOpen(for: sessionID) else { return }
        queue.async { [weak self] in
            guard let self, self.isOpen(for: sessionID) else { return }
            do {
                try write(sessionID, bytes)
                guard self.isOpen(for: sessionID) else { return }
                onSuccess(sessionID)
            } catch {
                self.closeIfCurrent(sessionID)
                onFailure(sessionID, error)
            }
        }
    }

    private func isOpen(for sessionID: BrokerSessionID) -> Bool {
        lock.withLock { openSessionID == sessionID }
    }

    private func closeIfCurrent(_ sessionID: BrokerSessionID) {
        lock.withLock {
            if openSessionID == sessionID {
                openSessionID = nil
            }
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
