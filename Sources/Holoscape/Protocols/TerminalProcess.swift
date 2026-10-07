import AppKit

/// Process-backed terminal surface used by channel controllers.
///
/// This is the first seam for #7168: controllers depend on an abstract
/// terminal process instead of hard-owning SwiftTerm's local-process view.
/// The current implementation remains `HoloscapeTerminalView`; a future
/// Holoscape session broker can implement the same operations while owning the
/// durable PTY process outside the UI view lifecycle.
@MainActor
protocol TerminalProcess: AnyObject {
    func startProcess(
        executable: String,
        args: [String],
        environment: [String]?,
        execName: String?,
        currentDirectory: String?
    )
    /// Reattach only to complete durable cleanup for a tab the user already
    /// closed. Unlike a user-visible start, this must not replay or acknowledge
    /// broker output and must never launch a replacement process.
    func resumeBrokerSessionForCleanup()

    func send(_ bytes: [UInt8])
    func setOutputHandler(_ handler: (() -> Void)?)
    /// Report host-provided current-directory updates such as OSC 7. Direct
    /// SwiftTerm-backed terminals can still use `LocalProcessTerminalViewDelegate`;
    /// broker-backed terminals expose their wrapped terminal view through this
    /// seam so shell tabs keep authoritative cwd truth without depending on
    /// typed-input heuristics.
    func setHostCurrentDirectoryHandler(_ handler: ((String?) -> Void)?)
    /// Report a failure observed while operating an already-started session
    /// (broker host outage, broker that no longer owns the session). The owning
    /// tab downgrades its recovery state from this instead of guessing.
    func setSessionFailureHandler(_ handler: ((TerminalSessionFailure) -> Void)?)
    /// Broker reattach can finish after `startProcess` returns. Controllers use
    /// this completion as the terminal-start commit point; direct terminals keep
    /// their historical synchronous behavior.
    func setStartCompletionHandler(_ handler: (() -> Void)?)
    var completesStartAsynchronously: Bool { get }
    func setUserInputHandler(_ handler: ((ArraySlice<UInt8>) -> Void)?)
    func setTerminationHandler(_ handler: ((Int32?) -> Void)?)
    func lastLines(_ count: Int) -> [String]
    func detachBrokerSession(completion: @escaping @MainActor () -> Void)
    /// Detach for a presentation-hidden close and report whether cleanup is
    /// durably complete. A retryable failure must keep the close tombstone and
    /// broker identity persisted so a later launch can resume cleanup.
    func detachBrokerSessionForCleanup(
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    )
    /// Detach for app termination without consuming unread broker output. Any
    /// final bytes remain broker-owned for replay on the next launch.
    func detachBrokerSessionPreservingOutput(completion: @escaping @MainActor () -> Void)
    /// Retire a session for a user-requested tab close. Success means no durable
    /// broker record can later resurrect the hidden tab.
    func retireBrokerSessionForClose(
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    )
    /// Persist host-reported cwd truth with the process owner. Direct terminals
    /// do not own durable metadata and therefore use the default no-op.
    func updateWorkingDirectory(_ directory: String) throws
    /// Forward the terminal view's current grid size to the underlying process
    /// owner. Direct SwiftTerm-backed terminals already resize their child PTY
    /// internally; broker-backed terminals must explicitly resize the broker
    /// session because SwiftTerm no longer owns the child process.
    func resizeToCurrentGrid()

    var terminalContentView: NSView { get }
    var currentGridSize: TerminalGridSize { get }
    var brokerOwnedSessionID: BrokerSessionID? { get }
    /// Generation token owned by the currently attached broker process. Direct
    /// terminals return nil; broker terminals restore it from durable metadata.
    var agentStatusOwnerToken: String? { get }
    /// Most recent failure observed on the live session, cleared by the next
    /// successful start/reattach. `nil` means the session is healthy.
    var sessionFailure: TerminalSessionFailure? { get }
    /// Identity of a broker session this terminal tried to reuse but the broker
    /// no longer owns. Reported only on a stale/missing-session failure so the
    /// owning tab can keep the recovery guidance and the tab/session
    /// association stable across relaunch.
    var staleBrokerSessionID: BrokerSessionID? { get }
    var startFailureDescription: String? { get }
    var startFailureKind: TerminalStartFailureKind? { get }
    var pendingExitedOutputRetirement: BrokerExitedOutputRetirement? { get }
}

enum TerminalStartFailureKind: String, Codable, Equatable, Sendable {
    case failed
    case brokerHostUnavailable
    case brokerSessionStale
}

/// Durable authority to retire an exited broker session without replaying its
/// already-presented final bytes again after failed acknowledgement/cleanup.
struct BrokerExitedOutputRetirement: Codable, Equatable, Sendable {
    let sessionID: BrokerSessionID
    let outputFailureDescription: String
    let outputFailureKind: TerminalStartFailureKind
    /// Known process exit truth, when final-output handling observed it before
    /// cleanup failed. Persisting this lets a later retirement retry publish the
    /// same terminal lifecycle outcome without replaying final bytes.
    let observedExitCode: Int32?

    init(
        sessionID: BrokerSessionID,
        outputFailureDescription: String,
        outputFailureKind: TerminalStartFailureKind,
        observedExitCode: Int32? = nil
    ) {
        self.sessionID = sessionID
        self.outputFailureDescription = outputFailureDescription
        self.outputFailureKind = outputFailureKind
        self.observedExitCode = observedExitCode
    }
}

/// A failure observed on an already-started terminal session.
///
/// `kind` reuses the start-failure classification so tab recovery guidance is
/// derived the same way whether the broker disappeared at start or mid-session.
struct TerminalSessionFailure: Equatable, Sendable {
    let kind: TerminalStartFailureKind
    let description: String
}

enum TerminalCleanupOutcome: Equatable, Sendable {
    case completed
    case retryableFailure(TerminalSessionFailure)
}

extension TerminalProcess {
    func resumeBrokerSessionForCleanup() {}
    func setHostCurrentDirectoryHandler(_ handler: ((String?) -> Void)?) {}
    func setTerminationHandler(_ handler: ((Int32?) -> Void)?) {}
    func setSessionFailureHandler(_ handler: ((TerminalSessionFailure) -> Void)?) {}
    func setStartCompletionHandler(_ handler: (() -> Void)?) {}
    var completesStartAsynchronously: Bool { false }
    func detachBrokerSession(completion: @escaping @MainActor () -> Void) { completion() }
    func detachBrokerSessionForCleanup(
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    ) {
        detachBrokerSession { completion(.completed) }
    }
    func detachBrokerSessionPreservingOutput(completion: @escaping @MainActor () -> Void) {
        detachBrokerSession(completion: completion)
    }
    func retireBrokerSessionForClose(
        completion: @escaping @MainActor (TerminalCleanupOutcome) -> Void
    ) {
        detachBrokerSessionForCleanup(completion: completion)
    }
    func detachBrokerSession() { detachBrokerSession(completion: {}) }
    func updateWorkingDirectory(_ directory: String) throws {}
    func resizeToCurrentGrid() {}
    var brokerOwnedSessionID: BrokerSessionID? { nil }
    var agentStatusOwnerToken: String? { nil }
    var sessionFailure: TerminalSessionFailure? { nil }
    var staleBrokerSessionID: BrokerSessionID? { nil }
    var startFailureDescription: String? { nil }
    var startFailureKind: TerminalStartFailureKind? { nil }
    var pendingExitedOutputRetirement: BrokerExitedOutputRetirement? { nil }
}
