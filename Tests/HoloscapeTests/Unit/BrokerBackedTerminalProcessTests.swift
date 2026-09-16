import XCTest
@testable import Holoscape

@MainActor
final class BrokerBackedTerminalProcessTests: XCTestCase {
    func testStartCreatesBrokerRecordAndRoutesInputThroughNativePTYRuntime() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerBackedTerminalProcessTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let runtime = NativePTYBrokerSessionRuntime()
        let coordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: runtime,
            now: { Date(timeIntervalSince1970: 700) }
        )
        let channelID = UUID(uuidString: "00000000-0000-0000-0000-000000008001")!
        let terminal = BrokerBackedTerminalProcess(
            channelID: channelID,
            channelType: .shell,
            label: "broker-cat",
            environmentProfile: .shell,
            coordinator: coordinator
        )
        var outputNotifications = 0
        terminal.setOutputHandler { outputNotifications += 1 }

        terminal.startProcess(
            executable: "/bin/cat",
            args: [],
            environment: nil,
            execName: "cat",
            currentDirectory: "/tmp"
        )
        guard let brokerSessionID = terminal.brokerSessionID else {
            return XCTFail("Broker-backed terminal did not expose a broker session id")
        }
        defer { _ = try? coordinator.markErrored(brokerSessionID) }
        defer { terminal.setOutputHandler(nil) }

        let record = try registry.load().single()
        XCTAssertEqual(record.id, brokerSessionID)
        XCTAssertEqual(record.channelType, .shell)
        XCTAssertEqual(record.label, "broker-cat")
        XCTAssertEqual(record.command, "/bin/cat")
        XCTAssertEqual(record.workingDirectory, "/tmp")
        XCTAssertEqual(record.environmentProfile, .shell)
        XCTAssertEqual(record.lifecycle, .running)
        XCTAssertEqual(record.lastAttachedChannelID, channelID)
        XCTAssertTrue(try coordinator.isRunning(brokerSessionID))

        terminal.send(Array("broker-terminal-bridge\n".utf8))
        try waitUntil {
            terminal.pollOutputOnce()
            return outputNotifications > 0
        }
        XCTAssertGreaterThan(outputNotifications, 0)
    }

    func testProcessExitUpdatesBrokerRecordAndCallsTerminationHandler() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerBackedTerminalProcessExitTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        var now = Date(timeIntervalSince1970: 800)
        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let coordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: NativePTYBrokerSessionRuntime(),
            now: { now }
        )
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(uuidString: "00000000-0000-0000-0000-000000008002")!,
            channelType: .shell,
            label: "broker-exit",
            environmentProfile: .shell,
            coordinator: coordinator
        )
        var observedExitCode: Int32?
        terminal.setTerminationHandler { observedExitCode = $0 }

        terminal.startProcess(
            executable: "/bin/sh",
            args: ["-c", "exit 3"],
            environment: nil,
            execName: "sh",
            currentDirectory: "/tmp"
        )
        now = Date(timeIntervalSince1970: 801)

        try waitUntil {
            terminal.pollOutputOnce()
            return observedExitCode != nil
        }

        XCTAssertEqual(observedExitCode, 3)
        let exited = try registry.load().single()
        XCTAssertEqual(exited.lifecycle, .exited)
        XCTAssertEqual(exited.exitCode, 3)
        XCTAssertNil(exited.lastAttachedChannelID)
        XCTAssertEqual(exited.updatedAt, now)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: () throws -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

private extension Array {
    func single(file: StaticString = #filePath, line: UInt = #line) throws -> Element {
        XCTAssertEqual(count, 1, file: file, line: line)
        return self[0]
    }
}
