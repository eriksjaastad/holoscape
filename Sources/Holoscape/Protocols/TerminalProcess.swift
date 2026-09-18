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
    func setUserInputHandler(_ handler: ((ArraySlice<UInt8>) -> Void)?)
    func setTerminationHandler(_ handler: ((Int32?) -> Void)?)
    func lastLines(_ count: Int) -> [String]
    func detachBrokerSession()

    var terminalContentView: NSView { get }
    var currentGridSize: TerminalGridSize { get }
    var brokerOwnedSessionID: BrokerSessionID? { get }
    var startFailureDescription: String? { get }
    var startFailureKind: TerminalStartFailureKind? { get }
}

enum TerminalStartFailureKind: Equatable, Sendable {
    case failed
    case brokerHostUnavailable
    case brokerSessionStale
}

extension TerminalProcess {
    func setTerminationHandler(_ handler: ((Int32?) -> Void)?) {}
    func detachBrokerSession() {}
    var brokerOwnedSessionID: BrokerSessionID? { nil }
    var startFailureDescription: String? { nil }
    var startFailureKind: TerminalStartFailureKind? { nil }
}
