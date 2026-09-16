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
}

/// Compatibility runtime used until the native broker process is introduced.
///
/// It intentionally does not launch a hidden fallback broker. Controllers still
/// start their existing SwiftTerm local process explicitly, while the
/// coordinator exercises the same runtime call sites that the durable broker
/// will implement.
struct MetadataOnlyBrokerSessionRuntime: BrokerSessionRuntime {
    func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {}
    func detachSession(id: BrokerSessionID) throws {}
    func attachSession(id: BrokerSessionID, channelID: UUID) throws {}
    func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {}
    func markSessionErrored(id: BrokerSessionID) throws {}
}
