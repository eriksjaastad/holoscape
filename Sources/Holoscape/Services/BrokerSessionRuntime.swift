import Foundation

/// Runtime boundary for broker-owned terminal sessions.
///
/// `BrokerSessionCoordinator` owns durable metadata transitions; this protocol is
/// the launch/attach/process side of the same contract. The current app still
/// uses SwiftTerm's local-process path through channel controllers, so the
/// default implementation records metadata only. The native out-of-process
/// broker will replace that implementation without changing controller calls.
protocol BrokerSessionRuntime {
    func listSessions() throws -> [BrokerSessionID]
    func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws
    func detachSession(id: BrokerSessionID) throws
    func attachSession(id: BrokerSessionID, channelID: UUID) throws
    func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws
    func markSessionErrored(id: BrokerSessionID) throws

    func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws
    func readAvailableOutput(id: BrokerSessionID) throws -> Data
    func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data
    func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws
    func isRunning(id: BrokerSessionID) throws -> Bool
    func terminationStatus(id: BrokerSessionID) throws -> Int32?
}

/// Optional launch capability used to prove that the runtime actually injected
/// the status-owner token into the child process. Older durable broker hosts can
/// decode the additive request field but return only the legacy `.ok` response;
/// callers must not persist ownership unless the runtime explicitly acknowledges it.
protocol BrokerSessionAgentStatusOwnerTokenAcknowledgingRuntime {
    func createSessionAcknowledgingAgentStatusOwnerToken(
        id: BrokerSessionID,
        request: BrokerSessionLaunchRequest
    ) throws -> Bool
}

enum ScrollbackReplaySource: String, Codable, Equatable, Sendable {
    case liveBrokerMemory
    case persistedDiskTail
    case unknown
}

struct ScrollbackReplay: Codable, Equatable, Sendable {
    let data: Data
    let source: ScrollbackReplaySource
    let maxBytes: Int
}

/// A non-destructive view of unread broker output. The runtime retains every
/// byte through `generation` until the client explicitly acknowledges it.
struct BrokerOutputSnapshot: Codable, Equatable, Sendable {
    let data: Data
    let generation: UInt64?
}

struct BrokerScrollbackReplaySnapshot: Codable, Equatable, Sendable {
    let replay: ScrollbackReplay
    let generation: UInt64?
}

protocol BrokerTransactionalOutputRuntime {
    func snapshotAvailableOutput(id: BrokerSessionID) throws -> BrokerOutputSnapshot
    func snapshotScrollbackReplay(id: BrokerSessionID, maxBytes: Int) throws -> BrokerScrollbackReplaySnapshot
    func acknowledgeOutput(id: BrokerSessionID, through generation: UInt64) throws
}

protocol ScrollbackReplayReportingRuntime {
    func readScrollbackReplay(id: BrokerSessionID, maxBytes: Int) throws -> ScrollbackReplay
}

protocol BrokerOutputAvailabilityMonitoringRuntime {
    var supportsOutputAvailabilityMonitoring: Bool { get }

    /// Installs a level-triggered availability handler. Implementations must
    /// invoke a non-nil handler when deliverable output or terminal state is
    /// already buffered, as well as when availability changes afterward.
    func setOutputAvailabilityHandler(
        id: BrokerSessionID,
        handler: (@Sendable (BrokerSessionID) -> Void)?
    ) throws
}

extension BrokerOutputAvailabilityMonitoringRuntime {
    var supportsOutputAvailabilityMonitoring: Bool { true }
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

    func listSessions() throws -> [BrokerSessionID] { [] }
    func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {}
    func detachSession(id: BrokerSessionID) throws {}
    func attachSession(id: BrokerSessionID, channelID: UUID) throws {}
    func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {}
    func markSessionErrored(id: BrokerSessionID) throws {}
    func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws { throw RuntimeError.unsupportedPTYOperation }
    func readAvailableOutput(id: BrokerSessionID) throws -> Data { throw RuntimeError.unsupportedPTYOperation }
    func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data { throw RuntimeError.unsupportedPTYOperation }
    func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws { throw RuntimeError.unsupportedPTYOperation }
    func isRunning(id: BrokerSessionID) throws -> Bool { throw RuntimeError.unsupportedPTYOperation }
    func terminationStatus(id: BrokerSessionID) throws -> Int32? { throw RuntimeError.unsupportedPTYOperation }
}
