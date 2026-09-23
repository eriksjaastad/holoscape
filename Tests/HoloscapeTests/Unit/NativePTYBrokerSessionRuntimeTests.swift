import Foundation
import XCTest
@testable import Holoscape

final class NativePTYBrokerSessionRuntimeTests: XCTestCase {
    func testLocalPTYSessionAcceptsInputProducesOutputResizesAndTerminates() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        XCTAssertTrue(try runtime.isRunning(id: id))
        try runtime.resizeSession(id: id, size: TerminalGridSize(columns: 100, rows: 30))
        try runtime.sendInput(id: id, bytes: Array("holoscape-native-pty\n".utf8))

        let output = try waitForOutput(from: runtime, id: id, containing: "holoscape-native-pty")
        XCTAssertTrue(output.contains("holoscape-native-pty"), output)

        try runtime.terminateSession(id: id, exitCode: nil)
        XCTAssertFalse(try runtime.isRunning(id: id))
        XCTAssertTrue(try runtime.readScrollbackTail(id: id, maxBytes: 4096).contains(Data("holoscape-native-pty".utf8)))
    }

    func testTerminatePreservesExitedSessionForScrollbackReads() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "terminated-scrollback-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "printf preserved-scrollback; exit 3"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }
        XCTAssertEqual(try waitForTerminationStatus(from: runtime, id: id), 3)
        _ = try waitForOutput(from: runtime, id: id, containing: "preserved-scrollback")

        try runtime.terminateSession(id: id, exitCode: 3)

        XCTAssertFalse(try runtime.isRunning(id: id))
        XCTAssertEqual(try runtime.terminationStatus(id: id), 3)
        XCTAssertEqual(try runtime.listSessions(), [id])
        let scrollback = String(decoding: try runtime.readScrollbackTail(id: id, maxBytes: 4096), as: UTF8.self)
        XCTAssertTrue(scrollback.contains("preserved-scrollback"), scrollback)
    }

    func testDuplicateSessionFailsLoudlyWithoutReplacingOriginalSession() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "duplicate-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        XCTAssertThrowsError(try runtime.createSession(id: id, request: request)) { error in
            XCTAssertEqual(error as? NativePTYBrokerSessionRuntime.RuntimeError, .duplicateSession(id))
        }
        XCTAssertTrue(try runtime.isRunning(id: id))
    }

    func testListSessionsReturnsStableSortedSessionIDsWithoutTouchingMissingSessions() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let firstID = BrokerSessionID(rawValue: "list-native-pty-runtime-b")
        let secondID = BrokerSessionID(rawValue: "list-native-pty-runtime-a")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        XCTAssertEqual(try runtime.listSessions(), [])
        try runtime.createSession(id: firstID, request: request)
        defer { try? runtime.markSessionErrored(id: firstID) }
        try runtime.createSession(id: secondID, request: request)
        defer { try? runtime.markSessionErrored(id: secondID) }

        XCTAssertEqual(try runtime.listSessions(), [secondID, firstID])
    }

    func testOperationsForMissingSessionFailLoudly() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "missing-native-pty-runtime-test")

        XCTAssertThrowsError(try runtime.sendInput(id: id, bytes: [])) { error in
            XCTAssertEqual(error as? NativePTYBrokerSessionRuntime.RuntimeError, .missingSession(id))
        }
        XCTAssertThrowsError(try runtime.readAvailableOutput(id: id)) { error in
            XCTAssertEqual(error as? NativePTYBrokerSessionRuntime.RuntimeError, .missingSession(id))
        }
        XCTAssertThrowsError(try runtime.resizeSession(id: id, size: TerminalGridSize(columns: 80, rows: 24))) { error in
            XCTAssertEqual(error as? NativePTYBrokerSessionRuntime.RuntimeError, .missingSession(id))
        }
        XCTAssertThrowsError(try runtime.isRunning(id: id)) { error in
            XCTAssertEqual(error as? NativePTYBrokerSessionRuntime.RuntimeError, .missingSession(id))
        }
    }

    func testReadAvailableOutputReturnsEmptyDataWhenNoOutputIsPending() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "empty-output-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        XCTAssertEqual(try runtime.readAvailableOutput(id: id), Data())
    }

    func testScrollbackTailRetainsOutputAfterPendingOutputIsConsumed() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "scrollback-tail-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        try runtime.sendInput(id: id, bytes: Array("first-scrollback-line\nsecond-scrollback-line\n".utf8))
        _ = try waitForOutput(from: runtime, id: id, containing: "second-scrollback-line")
        XCTAssertEqual(try runtime.readAvailableOutput(id: id), Data())

        let fullTail = String(decoding: try runtime.readScrollbackTail(id: id, maxBytes: 4096), as: UTF8.self)
        XCTAssertTrue(fullTail.contains("first-scrollback-line"), fullTail)
        XCTAssertTrue(fullTail.contains("second-scrollback-line"), fullTail)

        let clippedTail = try runtime.readScrollbackTail(id: id, maxBytes: 8)
        XCTAssertEqual(clippedTail.count, 8)
        XCTAssertTrue(String(decoding: clippedTail, as: UTF8.self).contains("line"))
        XCTAssertEqual(try runtime.readScrollbackTail(id: id, maxBytes: 0), Data())
    }

    func testDiskBackedScrollbackCanBeReadAfterRuntimeInstanceLoss() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativePTYBrokerSessionRuntimeScrollbackTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = BrokerSessionID(rawValue: "disk-backed-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "printf durable-scrollback; exit 0"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        let firstRuntime = NativePTYBrokerSessionRuntime(scrollbackDirectory: directory)
        try firstRuntime.createSession(id: id, request: request)
        _ = try waitForTerminationStatus(from: firstRuntime, id: id)
        _ = try waitForOutput(from: firstRuntime, id: id, containing: "durable-scrollback")

        let replacementRuntime = NativePTYBrokerSessionRuntime(scrollbackDirectory: directory)
        let restored = String(decoding: try replacementRuntime.readScrollbackTail(id: id, maxBytes: 4096), as: UTF8.self)
        let replay = try replacementRuntime.readScrollbackReplay(id: id, maxBytes: 4096)

        XCTAssertTrue(restored.contains("durable-scrollback"), restored)
        XCTAssertEqual(replay.source, .persistedDiskTail)
        XCTAssertTrue(String(decoding: replay.data, as: UTF8.self).contains("durable-scrollback"))
    }

    func testTerminationStatusIsNilWhileRunningAndExitCodeAfterProcessEnds() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "termination-status-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "exit 7"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        let exitCode = try waitForTerminationStatus(from: runtime, id: id)
        XCTAssertEqual(exitCode, 7)
        XCTAssertFalse(try runtime.isRunning(id: id))
    }

    func testShellProfileSetsDeterministicTerminalEnvironmentFromSparseGUIEnvironment() throws {
        let runtime = NativePTYBrokerSessionRuntime(processEnvironment: [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin",
            "SHELL": "/bin/zsh"
        ])
        let id = BrokerSessionID(rawValue: "shell-environment-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/usr/bin/env",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        _ = try waitForTerminationStatus(from: runtime, id: id)
        let output = try collectOutput(from: runtime, id: id)
        XCTAssertTrue(output.contains("TERM=xterm-256color"), output)
        XCTAssertTrue(output.contains("LANG=en_US.UTF-8"), output)
        XCTAssertTrue(output.contains("TERM_PROGRAM=Apple_Terminal"), output)
    }

    func testShellProfilePreservesExistingUTF8Locale() throws {
        let runtime = NativePTYBrokerSessionRuntime(processEnvironment: [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin",
            "SHELL": "/bin/zsh",
            "LANG": "C.UTF-8"
        ])
        let id = BrokerSessionID(rawValue: "shell-locale-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/usr/bin/env",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        _ = try waitForTerminationStatus(from: runtime, id: id)
        let output = try collectOutput(from: runtime, id: id)
        XCTAssertTrue(output.contains("LANG=C.UTF-8"), output)
        XCTAssertTrue(output.contains("TERM=xterm-256color"), output)
    }

    func testAgentOAuthProfileUsesCleanEnvironmentWithoutAPIKeyLeakage() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "agent-oauth-environment-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/usr/bin/env",
            workingDirectory: "/tmp",
            environmentProfile: .agentOAuth,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        _ = try waitForTerminationStatus(from: runtime, id: id)
        let output = try collectOutput(from: runtime, id: id)
        XCTAssertTrue(output.contains("TERM=xterm-256color"), output)
        XCTAssertFalse(output.contains("ANTHROPIC_API_KEY="), output)
    }

    func testAgentAPIProfileFailsLoudlyUntilKeychainRecipeExists() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "agent-api-environment-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/usr/bin/env",
            workingDirectory: "/tmp",
            environmentProfile: .agentAPI,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        XCTAssertThrowsError(try runtime.createSession(id: id, request: request)) { error in
            XCTAssertEqual(
                error as? NativePTYBrokerSessionRuntime.RuntimeError,
                .unsupportedEnvironmentProfile(
                    .agentAPI,
                    reason: "agent API broker sessions require a Keychain-backed environment recipe"
                )
            )
        }
        XCTAssertThrowsError(try runtime.isRunning(id: id)) { error in
            XCTAssertEqual(error as? NativePTYBrokerSessionRuntime.RuntimeError, .missingSession(id))
        }
    }

    private func waitForOutput(
        from runtime: NativePTYBrokerSessionRuntime,
        id: BrokerSessionID,
        containing expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        var collected = Data()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            collected.append(try runtime.readAvailableOutput(id: id))
            let output = String(decoding: collected, as: UTF8.self)
            if output.contains(expected) {
                return output
            }
            usleep(20_000)
        }
        let output = String(decoding: collected, as: UTF8.self)
        XCTFail("Timed out waiting for PTY output containing \(expected). Output: \(output)", file: file, line: line)
        return output
    }

    private func waitForTerminationStatus(
        from runtime: NativePTYBrokerSessionRuntime,
        id: BrokerSessionID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Int32? {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let status = try runtime.terminationStatus(id: id) {
                return status
            }
            usleep(20_000)
        }
        XCTFail("Timed out waiting for PTY termination status", file: file, line: line)
        return nil
    }

    private func collectOutput(
        from runtime: NativePTYBrokerSessionRuntime,
        id: BrokerSessionID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        var collected = Data()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let chunk = try runtime.readAvailableOutput(id: id)
            if chunk.isEmpty, !collected.isEmpty {
                return String(decoding: collected, as: UTF8.self)
            }
            collected.append(chunk)
            usleep(20_000)
        }
        let output = String(decoding: collected, as: UTF8.self)
        XCTFail("Timed out collecting PTY output. Output: \(output)", file: file, line: line)
        return output
    }
}
