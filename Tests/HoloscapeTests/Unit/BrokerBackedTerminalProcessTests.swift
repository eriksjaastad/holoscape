import XCTest
@testable import Holoscape

@MainActor
final class BrokerBackedTerminalProcessTests: XCTestCase {
    private enum RuntimeError: Error, Equatable {
        case createFailed
    }

    private final class FailingReattachRuntime: BrokerSessionRuntime {
        let reattachError: Error

        init(reattachError: Error) {
            self.reattachError = reattachError
        }

        func listSessions() throws -> [BrokerSessionID] { [] }
        func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws {}
        func detachSession(id: BrokerSessionID) throws {}
        func attachSession(id: BrokerSessionID, channelID: UUID) throws { throw reattachError }
        func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {}
        func markSessionErrored(id: BrokerSessionID) throws {}
        func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(id: BrokerSessionID) throws -> Data { Data() }
        func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data { Data() }
        func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(id: BrokerSessionID) throws -> Bool { true }
        func terminationStatus(id: BrokerSessionID) throws -> Int32? { nil }
    }

    private final class FailingCreateRuntime: BrokerSessionRuntime {
        func listSessions() throws -> [BrokerSessionID] { [] }
        func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws { throw RuntimeError.createFailed }
        func detachSession(id: BrokerSessionID) throws {}
        func attachSession(id: BrokerSessionID, channelID: UUID) throws {}
        func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {}
        func markSessionErrored(id: BrokerSessionID) throws {}
        func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(id: BrokerSessionID) throws -> Data { Data() }
        func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data { Data() }
        func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(id: BrokerSessionID) throws -> Bool { false }
        func terminationStatus(id: BrokerSessionID) throws -> Int32? { nil }
    }

    private final class StaleThenCreateRuntime: BrokerSessionRuntime {
        let staleID: BrokerSessionID
        var createdIDs: [BrokerSessionID] = []

        init(staleID: BrokerSessionID) {
            self.staleID = staleID
        }

        func listSessions() throws -> [BrokerSessionID] { createdIDs }
        func createSession(id: BrokerSessionID, request: BrokerSessionLaunchRequest) throws { createdIDs.append(id) }
        func detachSession(id: BrokerSessionID) throws {}
        func attachSession(id: BrokerSessionID, channelID: UUID) throws {
            if id == staleID {
                throw NativePTYBrokerSessionRuntime.RuntimeError.missingSession(id)
            }
        }
        func terminateSession(id: BrokerSessionID, exitCode: Int32?) throws {}
        func markSessionErrored(id: BrokerSessionID) throws {}
        func sendInput(id: BrokerSessionID, bytes: [UInt8]) throws {}
        func readAvailableOutput(id: BrokerSessionID) throws -> Data { Data() }
        func readScrollbackTail(id: BrokerSessionID, maxBytes: Int) throws -> Data { Data() }
        func resizeSession(id: BrokerSessionID, size: TerminalGridSize) throws {}
        func isRunning(id: BrokerSessionID) throws -> Bool { true }
        func terminationStatus(id: BrokerSessionID) throws -> Int32? { nil }
    }

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

    func testStartReattachesExistingBrokerSessionInsteadOfCreatingReplacement() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerBackedTerminalProcessReattachTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let coordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: NativePTYBrokerSessionRuntime(),
            now: { Date(timeIntervalSince1970: 900) }
        )
        let originalChannelID = UUID(uuidString: "00000000-0000-0000-0000-000000008003")!
        let restoredChannelID = UUID(uuidString: "00000000-0000-0000-0000-000000008004")!
        let record = try coordinator.start(
            BrokerSessionLaunchRequest(
                command: "/bin/cat",
                workingDirectory: "/tmp",
                environmentProfile: .shell,
                initialSize: TerminalGridSize(columns: 80, rows: 24)
            ),
            channelType: .shell,
            label: "broker-reattach",
            attachedChannelID: originalChannelID
        )
        try coordinator.sendInput(record.id, bytes: Array("before-ui-restore\n".utf8))
        _ = try waitForBrokerOutput(from: coordinator, id: record.id, containing: "before-ui-restore")
        _ = try coordinator.detach(record.id)

        let restoredTerminal = BrokerBackedTerminalProcess(
            channelID: restoredChannelID,
            channelType: .shell,
            label: "broker-reattach",
            environmentProfile: .shell,
            existingBrokerSessionID: record.id,
            coordinator: coordinator
        )
        var outputNotifications = 0
        restoredTerminal.setOutputHandler { outputNotifications += 1 }

        restoredTerminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh",
            currentDirectory: "/tmp"
        )
        restoredTerminal.send(Array("after-ui-restore\n".utf8))
        try waitUntil {
            restoredTerminal.pollOutputOnce()
            return outputNotifications > 0
        }

        let sessions = try registry.load()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, record.id)
        XCTAssertEqual(sessions[0].command, "/bin/cat")
        XCTAssertEqual(sessions[0].lifecycle, .running)
        XCTAssertEqual(sessions[0].lastAttachedChannelID, restoredChannelID)
        XCTAssertEqual(restoredTerminal.brokerSessionID, record.id)
        XCTAssertTrue(try coordinator.isRunning(record.id))
    }

    func testStartFailureIsObservableAndDoesNotExposePhantomBrokerSession() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerBackedTerminalProcessFailureTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let coordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: FailingCreateRuntime(),
            now: { Date(timeIntervalSince1970: 950) }
        )
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(uuidString: "00000000-0000-0000-0000-000000008005")!,
            channelType: .shell,
            label: "broker-failure",
            environmentProfile: .shell,
            coordinator: coordinator
        )

        terminal.startProcess(
            executable: "/bin/zsh",
            args: ["--login"],
            environment: nil,
            execName: "zsh",
            currentDirectory: "/tmp"
        )

        XCTAssertNil(terminal.brokerSessionID)
        XCTAssertTrue(terminal.startFailureDescription?.contains("createFailed") == true, terminal.startFailureDescription ?? "nil")
        XCTAssertEqual(terminal.startFailureKind, .failed)
        XCTAssertEqual(try registry.load(), [])
    }

    func testReattachMissingRuntimeSessionIsObservableAsStaleAndMarksRecordStale() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerBackedTerminalProcessStaleReattachTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sessionID = BrokerSessionID(rawValue: "stale-restored-agent-session")
        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        try registry.upsert(BrokerSessionRecord(
            id: sessionID,
            channelType: .agentDirect,
            label: "Codex",
            command: "/usr/bin/env",
            arguments: ["codex"],
            workingDirectory: "/tmp/stale-agent",
            environmentProfile: .agentOAuth,
            lifecycle: .detached,
            exitCode: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            lastAttachedChannelID: nil
        ))
        let coordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: FailingReattachRuntime(reattachError: NativePTYBrokerSessionRuntime.RuntimeError.missingSession(sessionID)),
            now: { Date(timeIntervalSince1970: 2) }
        )
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(uuidString: "00000000-0000-0000-0000-000000008006")!,
            channelType: .agentDirect,
            label: "Codex",
            environmentProfile: .agentOAuth,
            existingBrokerSessionID: sessionID,
            coordinator: coordinator
        )

        terminal.startProcess(
            executable: "/usr/bin/env",
            args: ["codex"],
            environment: nil,
            execName: "codex",
            currentDirectory: "/tmp/stale-agent"
        )

        XCTAssertNil(terminal.brokerSessionID)
        XCTAssertEqual(terminal.startFailureKind, .brokerSessionStale)
        XCTAssertEqual(
            terminal.staleBrokerSessionID,
            sessionID,
            "The dead session identity must be reported so the owning tab can persist its recreate guidance"
        )
        let stale = try registry.load().single()
        XCTAssertEqual(stale.lifecycle, .stale)
        XCTAssertNil(stale.lastAttachedChannelID)
    }

    func testReattachBrokerHostUnavailablePreservesSessionIDForRetry() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerBackedTerminalProcessHostUnavailableReattachTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let sessionID = BrokerSessionID(rawValue: "host-unavailable-restored-agent-session")
        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        let record = BrokerSessionRecord(
            id: sessionID,
            channelType: .agentDirect,
            label: "Codex",
            command: "/usr/bin/env",
            arguments: ["codex"],
            workingDirectory: "/tmp/host-unavailable-agent",
            environmentProfile: .agentOAuth,
            lifecycle: .detached,
            exitCode: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            lastAttachedChannelID: nil
        )
        try registry.upsert(record)
        let coordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: FailingReattachRuntime(reattachError: BrokerSessionHostClientRuntime.ClientError.transportFailed("socketTimedOut(/tmp/missing.sock)")),
            now: { Date(timeIntervalSince1970: 2) }
        )
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(uuidString: "00000000-0000-0000-0000-000000008007")!,
            channelType: .agentDirect,
            label: "Codex",
            environmentProfile: .agentOAuth,
            existingBrokerSessionID: sessionID,
            coordinator: coordinator
        )

        terminal.startProcess(
            executable: "/usr/bin/env",
            args: ["codex"],
            environment: nil,
            execName: "codex",
            currentDirectory: "/tmp/host-unavailable-agent"
        )

        XCTAssertEqual(terminal.brokerSessionID, sessionID)
        XCTAssertEqual(terminal.startFailureKind, .brokerHostUnavailable)
        XCTAssertEqual(try registry.load(), [record])
    }

    func testRetryAfterStaleReattachCreatesReplacementBrokerSession() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrokerBackedTerminalProcessStaleRetryTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let staleID = BrokerSessionID(rawValue: "stale-retry-restored-agent-session")
        let registry = BrokerSessionRegistry(fileURL: tempDirectory.appendingPathComponent("sessions.json"))
        try registry.upsert(BrokerSessionRecord(
            id: staleID,
            channelType: .agentDirect,
            label: "Codex",
            command: "/usr/bin/env",
            arguments: ["codex"],
            workingDirectory: "/tmp/stale-retry-agent",
            environmentProfile: .agentOAuth,
            lifecycle: .detached,
            exitCode: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            lastAttachedChannelID: nil
        ))
        let runtime = StaleThenCreateRuntime(staleID: staleID)
        var now = Date(timeIntervalSince1970: 2)
        let coordinator = BrokerSessionCoordinator(
            registry: registry,
            runtime: runtime,
            now: { now }
        )
        let terminal = BrokerBackedTerminalProcess(
            channelID: UUID(uuidString: "00000000-0000-0000-0000-000000008008")!,
            channelType: .agentDirect,
            label: "Codex",
            environmentProfile: .agentOAuth,
            existingBrokerSessionID: staleID,
            coordinator: coordinator
        )

        terminal.startProcess(
            executable: "/usr/bin/env",
            args: ["codex"],
            environment: nil,
            execName: "codex",
            currentDirectory: "/tmp/stale-retry-agent"
        )
        XCTAssertNil(terminal.brokerSessionID)
        XCTAssertEqual(terminal.startFailureKind, .brokerSessionStale)
        XCTAssertEqual(terminal.staleBrokerSessionID, staleID)

        now = Date(timeIntervalSince1970: 3)
        terminal.startProcess(
            executable: "/usr/bin/env",
            args: ["codex"],
            environment: nil,
            execName: "codex",
            currentDirectory: "/tmp/stale-retry-agent"
        )

        guard let replacementID = terminal.brokerSessionID else {
            return XCTFail("Expected stale retry to create a replacement broker session")
        }
        XCTAssertNil(terminal.startFailureKind)
        XCTAssertNil(terminal.staleBrokerSessionID, "A replacement session clears the dead identity")
        XCTAssertNotEqual(replacementID, staleID)
        XCTAssertEqual(runtime.createdIDs, [replacementID])
        let records = try registry.load().sorted { $0.createdAt < $1.createdAt }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].id, staleID)
        XCTAssertEqual(records[0].lifecycle, .stale)
        XCTAssertEqual(records[1].id, replacementID)
        XCTAssertEqual(records[1].lifecycle, .running)
        XCTAssertEqual(records[1].command, "/usr/bin/env")
        XCTAssertEqual(records[1].arguments, ["codex"])
        XCTAssertEqual(records[1].workingDirectory, "/tmp/stale-retry-agent")
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

    private func waitForBrokerOutput(
        from coordinator: BrokerSessionCoordinator,
        id: BrokerSessionID,
        containing expected: String,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        var collected = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            collected.append(try coordinator.readAvailableOutput(id))
            let output = String(decoding: collected, as: UTF8.self)
            if output.contains(expected) {
                return output
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        let output = String(decoding: collected, as: UTF8.self)
        XCTFail("Timed out waiting for broker output containing \(expected). Saw: \(output)", file: file, line: line)
        return output
    }
}

private extension Array {
    func single(file: StaticString = #filePath, line: UInt = #line) throws -> Element {
        XCTAssertEqual(count, 1, file: file, line: line)
        return self[0]
    }
}
