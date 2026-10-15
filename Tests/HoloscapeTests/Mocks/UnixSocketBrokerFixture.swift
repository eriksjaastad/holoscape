import Darwin
import Foundation
import XCTest
@testable import Holoscape

/// Test-only broker host with a real Unix socket and native PTY runtime.
///
/// The fixture owns the server thread, socket, and native sessions. Cleanup
/// retires sessions before asking the server to stop, then reports every
/// failure instead of leaving a background broker to contaminate later tests.
@MainActor
final class UnixSocketBrokerFixture {
    let directory: URL
    let socketPath: String
    let registry: BrokerSessionRegistry
    let coordinator: BrokerSessionCoordinator

    private let client: BrokerSessionHostClientRuntime
    private let stopSignal: BrokerSessionHostUnixSocketServer.StopSignal
    private let serverFinished = DispatchSemaphore(value: 0)
    private let serverFailure = UnixSocketBrokerServerFailure()

    init(timestamp: Date = Date(timeIntervalSince1970: 900)) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnixSocketBrokerFixture-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = "/tmp/hs-unix-fixture-\(UUID().uuidString).sock"
        registry = BrokerSessionRegistry(fileURL: directory.appendingPathComponent("sessions.json"))

        stopSignal = BrokerSessionHostUnixSocketServer.StopSignal()
        let server = BrokerSessionHostUnixSocketServer(
            socketPath: socketPath,
            host: BrokerSessionHost(runtime: NativePTYBrokerSessionRuntime())
        )
        let finished = serverFinished
        let failure = serverFailure
        let signal = stopSignal
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try server.run(maxConnections: 128, stopSignal: signal)
            } catch {
                failure.record(error)
            }
            finished.signal()
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline,
              !BrokerSessionHostUnixSocketServer.socketPathHasReachableBroker(socketPath) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard BrokerSessionHostUnixSocketServer.socketPathHasReachableBroker(socketPath) else {
            stopSignal.requestStop()
            guard serverFinished.wait(timeout: .now() + 2) == .success else {
                try? FileManager.default.removeItem(at: directory)
                throw UnixSocketBrokerFixtureError.serverDidNotStop
            }
            try? FileManager.default.removeItem(at: directory)
            throw UnixSocketBrokerFixtureError.serverDidNotStart(
                serverFailure.message ?? "the broker socket did not become reachable"
            )
        }

        let transport = BrokerSessionHostUnixSocketTransport(socketPath: socketPath)
        client = BrokerSessionHostClientRuntime(
            startsOutputAvailabilityMonitor: false
        ) { frame in
            try transport.sendFrame(frame)
        }
        coordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: client,
            now: { timestamp }
        )
    }

    func activeSessionIDs() throws -> [BrokerSessionID] {
        try client.listSessions()
    }

    func makeCoordinator(timestamp: Date) -> BrokerSessionCoordinator {
        BrokerSessionCoordinator(
            registry: registry,
            runtime: client,
            now: { timestamp }
        )
    }

    func cleanup() {
        var failures: [String] = []
        do {
            let sessionIDs = try client.listSessions()
            for id in sessionIDs {
                do {
                    try client.markSessionErrored(id: id)
                } catch {
                    failures.append("failed to retire \(id.rawValue): \(error)")
                }
            }
        } catch {
            failures.append("failed to enumerate sessions: \(error)")
        }
        stopSignal.requestStop()
        let serverJoined = serverFinished.wait(timeout: .now() + 3) == .success
        if !serverJoined {
            failures.append("server did not stop within 3 seconds")
        }
        if let message = serverFailure.message {
            failures.append("server failed: \(message)")
        }
        if FileManager.default.fileExists(atPath: socketPath) {
            failures.append("server socket remained after shutdown")
        }
        if BrokerSessionHostUnixSocketServer.socketPathHasActiveBrokerLock(socketPath) {
            failures.append("server lock remained active after shutdown")
        } else if unlink(socketPath + ".lock") != 0, errno != ENOENT {
            failures.append("failed to remove inactive server lock: \(String(cString: strerror(errno)))")
        }
        if serverJoined {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                failures.append("failed to remove fixture directory: \(error)")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }
}

enum UnixSocketBrokerFixtureError: Error {
    case serverDidNotStart(String)
    case serverDidNotStop
}

private final class UnixSocketBrokerServerFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMessage: String?

    var message: String? {
        lock.withLock { storedMessage }
    }

    func record(_ error: Error) {
        lock.withLock {
            storedMessage = String(describing: error)
        }
    }
}
