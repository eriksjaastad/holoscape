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

    private let cleanupClient: BrokerSessionHostClientRuntime
    private let stopSignal = BrokerSessionHostUnixSocketServer.StopSignal()
    private let serverFinished = DispatchSemaphore(value: 0)
    private let serverFailure = UnixSocketBrokerServerFailure()
    private var didCleanUp = false

    init(
        timestamp: Date = Date(timeIntervalSince1970: 900),
        directory requestedDirectory: URL? = nil,
        socketPath requestedSocketPath: String? = nil,
        serverStartDelay: TimeInterval = 0,
        readinessTimeout: TimeInterval = 2
    ) throws {
        directory = requestedDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("UnixSocketBrokerFixture-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = requestedSocketPath ?? "/tmp/hs-unix-fixture-\(UUID().uuidString).sock"
        registry = BrokerSessionRegistry(fileURL: directory.appendingPathComponent("sessions.json"))
        cleanupClient = Self.makeClient(socketPath: socketPath)
        coordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: Self.makeClient(socketPath: socketPath),
            now: { timestamp }
        )

        let server = BrokerSessionHostUnixSocketServer(
            socketPath: socketPath,
            host: BrokerSessionHost(runtime: NativePTYBrokerSessionRuntime())
        )
        let finished = serverFinished
        let failure = serverFailure
        let signal = stopSignal
        DispatchQueue.global(qos: .userInitiated).async {
            if serverStartDelay > 0 {
                Thread.sleep(forTimeInterval: serverStartDelay)
            }
            do {
                try server.run(maxConnections: 128, stopSignal: signal)
            } catch {
                failure.record(error)
            }
            finished.signal()
        }

        let deadline = Date().addingTimeInterval(readinessTimeout)
        while Date() < deadline,
              !BrokerSessionHostUnixSocketServer.socketPathHasReachableBroker(socketPath) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard BrokerSessionHostUnixSocketServer.socketPathHasReachableBroker(socketPath) else {
            var failures = [
                serverFailure.message ?? "the broker socket did not become reachable",
            ]
            failures.append(contentsOf: stopServerAndCleanArtifacts())
            throw UnixSocketBrokerFixtureError.initializationFailed(failures)
        }
    }

    func activeSessionIDs() throws -> [BrokerSessionID] {
        try cleanupClient.listSessions()
    }

    func makeCoordinator(timestamp: Date) -> BrokerSessionCoordinator {
        BrokerSessionCoordinator(
            registry: registry,
            runtime: Self.makeClient(socketPath: socketPath),
            now: { timestamp }
        )
    }

    func cleanup(file: StaticString = #filePath, line: UInt = #line) {
        guard !didCleanUp else { return }
        didCleanUp = true

        var failures: [String] = []
        do {
            let sessionIDs = try cleanupClient.listSessions()
            for id in sessionIDs {
                do {
                    try cleanupClient.markSessionErrored(id: id)
                } catch {
                    failures.append("failed to retire \(id.rawValue): \(error)")
                }
            }
        } catch {
            failures.append("failed to enumerate sessions: \(error)")
        }
        failures.append(contentsOf: stopServerAndCleanArtifacts())
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "), file: file, line: line)
    }

    private func stopServerAndCleanArtifacts() -> [String] {
        var failures: [String] = []
        stopSignal.requestStop()
        let serverJoined = serverFinished.wait(timeout: .now() + 3) == .success
        if !serverJoined {
            failures.append("server did not stop within 3 seconds")
        }
        if let message = serverFailure.message {
            failures.append("server failed: \(message)")
        }

        guard serverJoined else { return failures }

        if FileManager.default.fileExists(atPath: socketPath) {
            failures.append("server socket remained after shutdown")
        }
        let lockPath = socketPath + ".lock"
        if FileManager.default.fileExists(atPath: lockPath) {
            if BrokerSessionHostUnixSocketServer.socketPathHasActiveBrokerLock(socketPath) {
                failures.append("server lock remained active after shutdown")
            } else if unlink(lockPath) != 0, errno != ENOENT {
                failures.append("failed to remove inactive server lock: \(String(cString: strerror(errno)))")
            }
        }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            failures.append("failed to remove fixture directory: \(error)")
        }
        return failures
    }

    private static func makeClient(socketPath: String) -> BrokerSessionHostClientRuntime {
        let transport = BrokerSessionHostUnixSocketTransport(socketPath: socketPath)
        return BrokerSessionHostClientRuntime(startsOutputAvailabilityMonitor: false) { frame in
            try transport.sendFrame(frame)
        }
    }
}

enum UnixSocketBrokerFixtureError: Error, CustomStringConvertible {
    case initializationFailed([String])

    var description: String {
        switch self {
        case .initializationFailed(let failures):
            return failures.joined(separator: "; ")
        }
    }
}

private final class UnixSocketBrokerServerFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMessages: [String] = []

    var message: String? {
        lock.withLock {
            storedMessages.isEmpty ? nil : storedMessages.joined(separator: "; ")
        }
    }

    func record(_ error: Error) {
        record(String(describing: error))
    }

    func record(_ message: String) {
        lock.withLock {
            storedMessages.append(message)
        }
    }
}
