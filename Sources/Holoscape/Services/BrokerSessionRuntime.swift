import Foundation

/// Runtime boundary for broker-owned terminal sessions.
///
/// `BrokerSessionCoordinator` owns durable metadata transitions; this protocol is
/// the launch/attach/process side of the same contract. The current app still
/// uses SwiftTerm's local-process path through channel controllers, so the
/// default implementation records metadata only. The native out-of-process
/// broker will replace that implementation without changing controller calls.
protocol BrokerSessionRuntime {
    func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws
    func detachSession(id: BrokerSessionID) throws
    func attachSession(id: BrokerSessionID, channelID: UUID) throws
    func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws
    func markSessionErrored(id: BrokerSessionID) throws

    func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws
    func readAvailableOutput(id: BrokerSessionID) throws -> Data
    func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws
    func isRunning(id: BrokerSessionID) throws -> Bool
}

/// Compatibility runtime used until the native broker process is introduced.
///
/// It intentionally does not launch a hidden fallback broker. Controllers still
/// start their existing SwiftTerm local process explicitly, while the
/// coordinator exercises the same runtime call sites that the durable broker
/// will implement.
struct MetadataOnlyBrokerSessionRuntime: BrokerSessionRuntime {
    enum RuntimeError: Error, Equatable {
        case unsupportedPTYOperation
    }

    func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {}
    func detachSession(id: BrokerSessionID) throws {}
    func attachSession(id: BrokerSessionID, channelID: UUID) throws {}
    func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {}
    func markSessionErrored(id: BrokerSessionID) throws {}
    func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws { throw RuntimeError.unsupportedPTYOperation }
    func readAvailableOutput(id: BrokerSessionID) throws -> Data { throw RuntimeError.unsupportedPTYOperation }
    func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws { throw RuntimeError.unsupportedPTYOperation }
    func isRunning(id: BrokerSessionID) throws -> Bool { throw RuntimeError.unsupportedPTYOperation }
}
