import Foundation
import XCTest
@testable import Holoscape

/// Test-only broker host with a real Unix socket and native PTY runtime.
///
/// The bounded server lifetime keeps the fixture deterministic: cleanup drains
/// the remaining request budget, allowing the server to shut down its runtime
/// and remove the socket without touching AppKit windows or animations.
@MainActor
final class UnixSocketBrokerFixture {
    let directory: URL
    let socketPath: String
    let registry: BrokerSessionRegistry
    let coordinator: BrokerSessionCoordinator

    private let client: BrokerSessionHostClientRuntime
    private let requestBudget = 128
    private let serverFinished = DispatchSemaphore(value: 0)
    private let serverFailure = UnixSocketBrokerServerFailure()

    init(timestamp: Date = Date(timeIntervalSince1970: 900)) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnixSocketBrokerFixture-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = "/tmp/hs-unix-fixture-\(UUID().uuidString).sock"
        registry = BrokerSessionRegistry(fileURL: directory.appendingPathComponent("sessions.json"))

        let server = BrokerSessionHostUnixSocketServer(
            socketPath: socketPath,
            host: BrokerSessionHost(runtime: NativePTYBrokerSessionRuntime())
        )
        let finished = serverFinished
        let failure = serverFailure
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try server.run(maxConnections: 128)
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
            throw UnixSocketBrokerFixtureError.serverDidNotStart
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
        for _ in 0..<requestBudget {
            guard (try? client.listSessions()) != nil else { break }
        }
        XCTAssertEqual(serverFinished.wait(timeout: .now() + 2), .success)
        XCTAssertNil(serverFailure.message)
        XCTAssertNoThrow(try FileManager.default.removeItem(at: directory))
    }
}

enum UnixSocketBrokerFixtureError: Error {
    case serverDidNotStart
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
