import Darwin
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

    func testPTYSessionReportsARealTTYInsteadOfAPlainPipe() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "tty-smoke-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-lc", "tty"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        _ = try waitForTerminationStatus(from: runtime, id: id)
        let output = try collectOutput(from: runtime, id: id)
        XCTAssertTrue(output.contains("/dev/tty"), output)
        XCTAssertFalse(output.localizedCaseInsensitiveContains("not a tty"), output)
    }

    func testPTYSessionSttySizeReflectsInitialAndResizedGrid() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "stty-size-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-lc", "stty size; read _; stty size"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 81, rows: 22)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        let initialOutput = try waitForOutput(from: runtime, id: id, containing: "22 81")
        XCTAssertTrue(initialOutput.contains("22 81"), initialOutput)

        try runtime.resizeSession(id: id, size: TerminalGridSize(columns: 132, rows: 43))
        try runtime.sendInput(id: id, bytes: Array("continue\n".utf8))
        _ = try waitForTerminationStatus(from: runtime, id: id)
        let resizedOutput = try collectOutput(from: runtime, id: id)
        XCTAssertTrue(resizedOutput.contains("43 132"), resizedOutput)
    }

    func testCreateSessionRejectsGridDimensionsThatDoNotFitPTYWinsize() {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "oversized-create-grid-native-pty-runtime-test")
        let oversized = Int(UInt16.max) + 1
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: oversized, rows: 24)
        )

        XCTAssertThrowsError(try runtime.createSession(id: id, request: request)) { error in
            XCTAssertEqual(
                error as? NativePTYBrokerSessionRuntime.RuntimeError,
                .invalidGridSize(TerminalGridSize(columns: oversized, rows: 24))
            )
        }
        XCTAssertThrowsError(try runtime.isRunning(id: id)) { error in
            XCTAssertEqual(error as? NativePTYBrokerSessionRuntime.RuntimeError, .missingSession(id))
        }
    }

    func testCreateSessionRejectsNonPositiveGridDimensionsDecodedFromBrokerProtocol() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "negative-create-grid-native-pty-runtime-test")
        let invalidSize = try JSONDecoder().decode(
            TerminalGridSize.self,
            from: Data(#"{"columns":80,"rows":-1}"#.utf8)
        )
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: invalidSize
        )

        XCTAssertThrowsError(try runtime.createSession(id: id, request: request)) { error in
            XCTAssertEqual(
                error as? NativePTYBrokerSessionRuntime.RuntimeError,
                .invalidGridSize(invalidSize)
            )
        }
        XCTAssertThrowsError(try runtime.isRunning(id: id)) { error in
            XCTAssertEqual(error as? NativePTYBrokerSessionRuntime.RuntimeError, .missingSession(id))
        }
    }

    func testResizeSessionRejectsGridDimensionsThatDoNotFitPTYWinsizeAndKeepsSessionRunning() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "oversized-resize-grid-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        let oversizedSize = TerminalGridSize(columns: 80, rows: Int(UInt16.max) + 1)

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        XCTAssertThrowsError(try runtime.resizeSession(id: id, size: oversizedSize)) { error in
            XCTAssertEqual(
                error as? NativePTYBrokerSessionRuntime.RuntimeError,
                .invalidGridSize(oversizedSize)
            )
        }
        XCTAssertTrue(try runtime.isRunning(id: id))
    }

    func testResizeSessionRejectsNonPositiveGridDimensionsDecodedFromBrokerProtocol() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "negative-resize-grid-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/cat",
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        let invalidSize = try JSONDecoder().decode(
            TerminalGridSize.self,
            from: Data(#"{"columns":-1,"rows":24}"#.utf8)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        XCTAssertThrowsError(try runtime.resizeSession(id: id, size: invalidSize)) { error in
            XCTAssertEqual(
                error as? NativePTYBrokerSessionRuntime.RuntimeError,
                .invalidGridSize(invalidSize)
            )
        }
        XCTAssertTrue(try runtime.isRunning(id: id))
    }

    func testPTYSessionLaunchesInRequestedWorkingDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativePTYBrokerSessionRuntimeCwdTests-")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // /var/... on macOS is a symlink to /private/var/...; resolve it so the
        // PTY child's getcwd() output matches the directory we actually created.
        let resolvedDirectory = directory.resolvingSymlinksInPath().path

        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "cwd-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/pwd",
            workingDirectory: resolvedDirectory,
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        _ = try waitForTerminationStatus(from: runtime, id: id)
        let output = try collectOutput(from: runtime, id: id)
        XCTAssertTrue(output.contains(resolvedDirectory), output)
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

    func testTerminateForceKillsProcessThatIgnoresSIGTERMWithinBoundedTime() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "sigterm-resistant-terminate-native-pty-runtime-test")
        let pids = try createSIGTERMResistantSession(runtime: runtime, id: id)
        defer {
            _ = Darwin.kill(pids.root, SIGKILL)
            _ = Darwin.kill(pids.child, SIGKILL)
            try? runtime.markSessionErrored(id: id)
        }
        let completed = DispatchSemaphore(value: 0)
        let capturedError = LockedRuntimeErrorBox()

        DispatchQueue.global().async {
            do {
                try runtime.terminateSession(id: id, exitCode: nil)
            } catch {
                capturedError.store(error)
            }
            completed.signal()
        }

        let firstWait = completed.wait(timeout: .now() + 1.5)
        if firstWait == .timedOut {
            _ = Darwin.kill(pids.root, SIGKILL)
            _ = Darwin.kill(pids.child, SIGKILL)
            _ = completed.wait(timeout: .now() + 1)
        }

        XCTAssertEqual(firstWait, .success, "termination exceeded its bounded deadline")
        XCTAssertNil(capturedError.value)
        XCTAssertFalse(try runtime.isRunning(id: id))
        XCTAssertNotNil(try runtime.terminationStatus(id: id))
        XCTAssertTrue(waitForProcessToExit(pids.child), "termination left descendant PID \(pids.child) running")
    }

    func testMarkErroredForceKillsProcessThatIgnoresSIGTERMWithinBoundedTime() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "sigterm-resistant-error-native-pty-runtime-test")
        let pids = try createSIGTERMResistantSession(runtime: runtime, id: id)
        defer {
            _ = Darwin.kill(pids.root, SIGKILL)
            _ = Darwin.kill(pids.child, SIGKILL)
        }
        let completed = DispatchSemaphore(value: 0)
        let capturedError = LockedRuntimeErrorBox()

        DispatchQueue.global().async {
            do {
                try runtime.markSessionErrored(id: id)
            } catch {
                capturedError.store(error)
            }
            completed.signal()
        }

        let firstWait = completed.wait(timeout: .now() + 1.5)
        if firstWait == .timedOut {
            _ = Darwin.kill(pids.root, SIGKILL)
            _ = Darwin.kill(pids.child, SIGKILL)
            _ = completed.wait(timeout: .now() + 1)
        }

        XCTAssertEqual(firstWait, .success, "error cleanup exceeded its bounded deadline")
        XCTAssertNil(capturedError.value)
        XCTAssertThrowsError(try runtime.isRunning(id: id)) { runtimeError in
            XCTAssertEqual(runtimeError as? NativePTYBrokerSessionRuntime.RuntimeError, .missingSession(id))
        }
        XCTAssertTrue(waitForProcessToExit(pids.root), "error cleanup left root PID \(pids.root) running")
        XCTAssertTrue(waitForProcessToExit(pids.child), "error cleanup left descendant PID \(pids.child) running")
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

    func testPTYEOFStopsOutputMonitoring() throws {
        let runtime = NativePTYBrokerSessionRuntime()
        let id = BrokerSessionID(rawValue: "eof-output-monitoring-native-pty-runtime-test")
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: ["-c", "printf eof-output; exit 0"],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )

        try runtime.createSession(id: id, request: request)
        defer { try? runtime.markSessionErrored(id: id) }

        _ = try waitForOutput(from: runtime, id: id, containing: "eof-output")
        _ = try waitForTerminationStatus(from: runtime, id: id)

        let deadline = Date().addingTimeInterval(3)
        while try runtime.isOutputMonitoring(id: id), Date() < deadline {
            usleep(20_000)
        }

        XCTAssertFalse(try runtime.isOutputMonitoring(id: id))
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

    func testRejectedEnvironmentProfilesDoNotLeakPTYFileDescriptors() {
        let runtime = NativePTYBrokerSessionRuntime()
        let request = BrokerSessionLaunchRequest(
            command: "/usr/bin/env",
            workingDirectory: "/tmp",
            environmentProfile: .agentAPI,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        let descriptorCountBefore = openFileDescriptorCount()

        for index in 0..<32 {
            let id = BrokerSessionID(rawValue: "rejected-environment-fd-leak-\(index)")
            XCTAssertThrowsError(try runtime.createSession(id: id, request: request))
        }

        XCTAssertEqual(openFileDescriptorCount(), descriptorCountBefore)
    }

    private func openFileDescriptorCount() -> Int {
        (0..<Int(getdtablesize())).reduce(into: 0) { count, descriptor in
            errno = 0
            if fcntl(Int32(descriptor), F_GETFD) != -1 || errno != EBADF {
                count += 1
            }
        }
    }

    private func createSIGTERMResistantSession(
        runtime: NativePTYBrokerSessionRuntime,
        id: BrokerSessionID
    ) throws -> (root: pid_t, child: pid_t) {
        let request = BrokerSessionLaunchRequest(
            command: "/bin/sh",
            arguments: [
                "-c",
                "ready=0; trap 'ready=1' USR1; trap '' TERM; /bin/sh -c 'trap \"\" TERM; kill -USR1 \"$1\"; while :; do :; done' sh \"$$\" & child=$!; while [ \"$ready\" -eq 0 ]; do :; done; printf 'SIGTERM_READY:%d:%d\\n' \"$$\" \"$child\"; wait \"$child\""
            ],
            workingDirectory: "/tmp",
            environmentProfile: .shell,
            initialSize: TerminalGridSize(columns: 80, rows: 24)
        )
        try runtime.createSession(id: id, request: request)
        do {
            let output = try waitForOutput(from: runtime, id: id, containing: "SIGTERM_READY:")
            guard let marker = output.range(of: "SIGTERM_READY:") else {
                throw CocoaError(.coderReadCorrupt)
            }
            let components = output[marker.upperBound...]
                .prefix(while: { $0.isNumber || $0 == ":" })
                .split(separator: ":")
            guard components.count == 2,
                  let rootPID = pid_t(components[0]),
                  let childPID = pid_t(components[1]) else {
                throw CocoaError(.coderReadCorrupt)
            }
            return (rootPID, childPID)
        } catch {
            do {
                try runtime.markSessionErrored(id: id)
            } catch let cleanupError {
                XCTFail("Fixture setup failed with \(error); cleanup also failed with \(cleanupError)")
                throw cleanupError
            }
            XCTFail("Could not prepare SIGTERM-resistant process tree: \(error)")
            throw error
        }
    }

    private func waitForProcessToExit(_ pid: pid_t) -> Bool {
        for _ in 0..<100 {
            if Darwin.kill(pid, 0) == -1, errno == ESRCH {
                return true
            }
            usleep(10_000)
        }
        return false
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

private final class LockedRuntimeErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var value: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func store(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }
}
