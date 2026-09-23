import Foundation
@testable import Holoscape

/// Broker runtime double whose operations can be made to fail on demand.
///
/// Used to drive coordinator-backed channel paths (SSH, and injected-coordinator
/// shell/agent channels) against a broker host that is unreachable or that has
/// dropped the session. Every attempt is recorded before it fails so tests can
/// assert the channel actually tried, then stayed recoverable.
final class FailingBrokerSessionRuntime: BrokerSessionRuntime {
    enum Mode {
        case healthy
        /// The broker host socket is unreachable.
        case hostUnavailable
        /// The broker is reachable but no longer owns the session.
        case sessionDropped
    }

    var mode: Mode = .healthy
    private(set) var createdIDs: [BrokerSessionID] = []
    private(set) var attachedIDs: [BrokerSessionID] = []
    private(set) var detachedIDs: [BrokerSessionID] = []
    private(set) var exitedIDs: [BrokerSessionID] = []
    private(set) var erroredIDs: [BrokerSessionID] = []
    private(set) var isRunningCalls: [BrokerSessionID] = []

    private func failIfNeeded(_ id: BrokerSessionID) throws {
        switch mode {
        case .healthy:
            return
        case .hostUnavailable:
            throw BrokerSessionHostClientRuntime.ClientError.transportFailed(
                "socketTimedOut(/tmp/holoscape-broker.sock)"
            )
        case .sessionDropped:
            throw NativePTYBrokerSessionRuntime.RuntimeError.missingSession(id)
        }
    }

    func listSessions() throws -> [BrokerSessionID] { createdIDs }

    func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {
        try failIfNeeded(id)
        createdIDs.append(id)
    }

    func detachSession(id: BrokerSessionID) throws {
        detachedIDs.append(id)
        try failIfNeeded(id)
    }

    func attachSession(id: BrokerSessionID, channelID: UUID) throws {
        attachedIDs.append(id)
        try failIfNeeded(id)
    }

    func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {
        exitedIDs.append(id)
        try failIfNeeded(id)
    }

    func markSessionErrored(id: BrokerSessionID) throws {
        erroredIDs.append(id)
        try failIfNeeded(id)
    }

    func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {
        try failIfNeeded(id)
    }

    func readAvailableOutput(id: BrokerSessionID) throws -> Data {
        try failIfNeeded(id)
        return Data()
    }

    func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data {
        try failIfNeeded(id)
        return Data()
    }

    func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {
        try failIfNeeded(id)
    }

    func isRunning(id: BrokerSessionID) throws -> Bool {
        isRunningCalls.append(id)
        try failIfNeeded(id)
        return true
    }

    func terminationStatus(id: BrokerSessionID) throws -> Int32? {
        try failIfNeeded(id)
        return nil
    }
}
