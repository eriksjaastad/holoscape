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

    func send(_ bytes: [UInt8])
    func setOutputHandler(_ handler: (() -> Void)?)
    /// Report a failure observed while operating an already-started session
    /// (broker host outage, broker that no longer owns the session). The owning
    /// tab downgrades its recovery state from this instead of guessing.
    func setSessionFailureHandler(_ handler: ((TerminalSessionFailure) -> Void)?)
    func setUserInputHandler(_ handler: ((ArraySlice<UInt8>) -> Void)?)
    func setTerminationHandler(_ handler: ((Int32?) -> Void)?)
    func lastLines(_ count: Int) -> [String]
    func detachBrokerSession()

    var terminalContentView: NSView { get }
    var currentGridSize: TerminalGridSize { get }
    var brokerOwnedSessionID: BrokerSessionID? { get }
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
}

enum TerminalStartFailureKind: Equatable, Sendable {
    case failed
    case brokerHostUnavailable
    case brokerSessionStale
}

/// A failure observed on an already-started terminal session.
///
/// `kind` reuses the start-failure classification so tab recovery guidance is
/// derived the same way whether the broker disappeared at start or mid-session.
struct TerminalSessionFailure: Equatable, Sendable {
    let kind: TerminalStartFailureKind
    let description: String
}

extension TerminalProcess {
    func setTerminationHandler(_ handler: ((Int32?) -> Void)?) {}
    func setSessionFailureHandler(_ handler: ((TerminalSessionFailure) -> Void)?) {}
    func detachBrokerSession() {}
    var brokerOwnedSessionID: BrokerSessionID? { nil }
    var sessionFailure: TerminalSessionFailure? { nil }
    var staleBrokerSessionID: BrokerSessionID? { nil }
    var startFailureDescription: String? { nil }
    var startFailureKind: TerminalStartFailureKind? { nil }
}
