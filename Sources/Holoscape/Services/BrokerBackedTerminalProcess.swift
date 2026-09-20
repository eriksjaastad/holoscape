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
    private let terminalView: HoloscapeTerminalView
    private var outputHandler: (() -> Void)?
    private var sessionFailureHandler: ((TerminalSessionFailure) -> Void)?
    private var userInputHandler: ((ArraySlice<UInt8>) -> Void)?
    private var terminationHandler: ((Int32?) -> Void)?
    private var outputTimer: Timer?
    private(set) var brokerSessionID: BrokerSessionID?
    /// Identity of the broker session this terminal failed to reattach because
    /// the broker no longer owns it. Kept separate from `brokerSessionID` so a
    /// retry spawns the replacement the stale guidance promises instead of
    /// reattaching the dead session, while the owning tab can still persist the
    /// dead identity for the next launch.
    private(set) var staleBrokerSessionID: BrokerSessionID?
    private var didNotifyTermination = false
    /// Most recent failure observed while operating the live session. `nil` means
    /// the session is healthy (or has not started yet).
    private(set) var sessionFailure: TerminalSessionFailure?
    private(set) var startFailureDescription: String?
    private(set) var startFailureKind: TerminalStartFailureKind?

    var terminalContentView: NSView { terminalView }
    var currentGridSize: TerminalGridSize { terminalView.currentGridSize }
    var brokerOwnedSessionID: BrokerSessionID? { brokerSessionID }

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
        self.terminalView = terminalView
        self.brokerSessionID = existingBrokerSessionID

        terminalView.setUserInputHandler { [weak self] data in
            guard let self else { return }
            self.userInputHandler?(data)
            self.send(Array(data))
        }
    }

    func startProcess(
        executable: String,
        args: [String],
        environment: [String]?,
        execName: String?,
        currentDirectory: String?
    ) {
        startFailureDescription = nil
        startFailureKind = nil
        staleBrokerSessionID = nil
        sessionFailure = nil
        if let existingBrokerSessionID = brokerSessionID {
            reattachExistingSession(existingBrokerSessionID)
            return
        }

        let request = BrokerSessionLaunchRequest(
            command: executable,
            arguments: args,
            workingDirectory: currentDirectory,
            environmentProfile: environmentProfile,
            initialSize: currentGridSize
        )

        do {
            let record = try coordinator.start(
                request,
                channelType: channelType,
                label: label,
                attachedChannelID: channelID
            )
            brokerSessionID = record.id
            if outputHandler != nil {
                startOutputPump()
            }
        } catch {
            brokerSessionID = nil
            startFailureDescription = String(describing: error)
            startFailureKind = classifyStartFailure(error)
            NSLog("Broker-backed terminal start failed: \(error)")
        }
    }

    private func reattachExistingSession(_ sessionID: BrokerSessionID) {
        startFailureDescription = nil
        startFailureKind = nil
        staleBrokerSessionID = nil
        sessionFailure = nil
        do {
            let record = try coordinator.reattach(sessionID, attachedChannelID: channelID)
            brokerSessionID = record.id
            let tail = try coordinator.readScrollbackTail(
                record.id,
                maxBytes: ScrollbackPersistencePolicy.maxReplayBytesOnReattach
            )
            if !tail.isEmpty {
                let bytes = Array(tail)
                terminalView.feed(byteArray: bytes[...])
                outputHandler?()
            }
            if outputHandler != nil {
                startOutputPump()
            }
        } catch {
            startFailureDescription = String(describing: error)
            startFailureKind = classifyStartFailure(error)
            switch startFailureKind {
            case .brokerHostUnavailable:
                // The host is unreachable but the session may still be alive:
                // keep the handle so retry reattaches instead of replacing it.
                brokerSessionID = sessionID
            case .brokerSessionStale:
                // The broker no longer owns this session. Drop the live handle so
                // retry spawns a replacement, and report the dead identity so the
                // tab can keep its recreate guidance across relaunch.
                brokerSessionID = nil
                staleBrokerSessionID = sessionID
            case .failed, .none:
                brokerSessionID = nil
            }
            NSLog("Broker-backed terminal reattach failed: \(error)")
        }
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
        do {
            try coordinator.sendInput(brokerSessionID, bytes: bytes)
            pollOutputOnce()
        } catch {
            reportSessionFailure(error)
        }
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

    func setUserInputHandler(_ handler: ((ArraySlice<UInt8>) -> Void)?) {
        userInputHandler = handler
    }

    func setTerminationHandler(_ handler: ((Int32?) -> Void)?) {
        terminationHandler = handler
    }

    func lastLines(_ count: Int) -> [String] {
        terminalView.lastLines(count)
    }

    func detachBrokerSession() {
        guard let brokerSessionID, !didNotifyTermination else { return }
        stopOutputPump()
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
    }

    func pollOutputOnce() {
        guard sessionFailure == nil else { return }
        guard let brokerSessionID else { return }
        do {
            let data = try coordinator.readAvailableOutput(brokerSessionID)
            if !data.isEmpty {
                let bytes = Array(data)
                terminalView.feed(byteArray: bytes[...])
                outputHandler?()
            }
            try notifyTerminationIfNeeded(for: brokerSessionID)
        } catch {
            reportSessionFailure(error)
        }
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
            reportSessionFailure(error)
        }
    }

    private func startOutputPump() {
        outputTimer?.invalidate()
        outputTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollOutputOnce()
            }
        }
    }

    private func stopOutputPump() {
        outputTimer?.invalidate()
        outputTimer = nil
    }

    /// Record a mid-session broker failure once, stop polling, and report it so
    /// the owning tab can downgrade to an explicit recovery state.
    ///
    /// The broker host disappearing underneath a running tab is an expected
    /// runtime condition, so it is reported through the session-failure boundary
    /// instead of trapping. The durable broker handle is preserved for the
    /// retryable cases so retry reattaches the same session rather than starting
    /// a replacement.
    private func reportSessionFailure(_ error: Error) {
        let kind = classifyStartFailure(error)
        switch kind {
        case .brokerHostUnavailable, .failed:
            // The host is unreachable (or the failure is unclassified) but the
            // session may still be alive: keep the handle so retry reattaches it.
            break
        case .brokerSessionStale:
            // The broker no longer owns the session: hand the dead identity to the
            // tab and drop the live handle so retry starts a replacement.
            if let sessionID = brokerSessionID {
                brokerSessionID = nil
                staleBrokerSessionID = sessionID
            }
        }

        let failure = TerminalSessionFailure(kind: kind, description: String(describing: error))
        guard sessionFailure != failure else {
            NSLog("Broker-backed terminal session still failing: \(failure.description)")
            return
        }
        sessionFailure = failure
        stopOutputPump()
        NSLog("Broker-backed terminal session failed (\(failure.kind)): \(failure.description)")
        sessionFailureHandler?(failure)
    }

    private func notifyTerminationIfNeeded(for brokerSessionID: BrokerSessionID) throws {
        guard !didNotifyTermination else { return }
        guard try !coordinator.isRunning(brokerSessionID) else { return }
        let exitCode = try coordinator.terminationStatus(brokerSessionID)
        didNotifyTermination = true
        outputTimer?.invalidate()
        outputTimer = nil
        if let exitCode {
            _ = try coordinator.exit(brokerSessionID, exitCode: exitCode)
        } else {
            _ = try coordinator.markErrored(brokerSessionID)
        }
        terminationHandler?(exitCode)
    }

    private func classifyStartFailure(_ error: Error) -> TerminalStartFailureKind {
        if let coordinatorError = error as? BrokerSessionCoordinator.CoordinatorError {
            switch coordinatorError {
            case .missingSession, .staleSession:
                return .brokerSessionStale
            case .brokerHostUnavailable:
                return .brokerHostUnavailable
            }
        }
        if case BrokerSessionHostClientRuntime.ClientError.transportFailed = error {
            return .brokerHostUnavailable
        }
        if let runtimeError = error as? NativePTYBrokerSessionRuntime.RuntimeError,
           case .missingSession = runtimeError {
            return .brokerSessionStale
        }
        if case let BrokerSessionHostClientRuntime.ClientError.hostFailure(code, message) = error,
           code == "missing-session",
           message.contains("missingSession") {
            return .brokerSessionStale
        }
        return .failed
    }
}
