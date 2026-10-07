import Darwin
import XCTest
@testable import HoloscapeMCP

final class ProcessToolTests: XCTestCase {
    private var launcherExecutableURL: URL {
        Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("HoloscapeMCP")
    }

    func testControllerStatusParsesCleanupFailureOutsideProcessOutput() {
        XCTAssertEqual(
            parseProcessToolControllerStatus("timedOut:groupSignalFailed"),
            .timedOut(groupCleanupSucceeded: false)
        )
        XCTAssertEqual(
            parseProcessToolControllerStatus("completed:17"),
            .completed(exitCode: 17)
        )
        XCTAssertEqual(
            parseProcessToolControllerStatus("completedCleanupFailed:17"),
            .completedCleanupFailed(exitCode: 17)
        )
        XCTAssertEqual(
            parseProcessToolControllerStatus("cancelled:groupSignaled"),
            .cancelled(groupCleanupSucceeded: true)
        )
        XCTAssertEqual(
            parseProcessToolControllerStatus("cancelled:groupSignalFailed"),
            .cancelled(groupCleanupSucceeded: false)
        )
        XCTAssertNil(parseProcessToolControllerStatus("timedOut:maybe"))
    }

    func testBoundedChildWaitReturnsWhileChildIsStillRunning() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        let child = process.processIdentifier
        defer {
            _ = Darwin.kill(child, SIGKILL)
            process.waitUntilExit()
        }

        let startedAt = DispatchTime.now()
        let result = waitForProcessToolChild(child, timeoutSeconds: 0.05)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000_000

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 0.5, "Cleanup failure must not turn a timeout into an unbounded wait")
    }

    func testPipeReaderWaitsForInFlightAppendBeforeSnapshot() throws {
        let pipe = Pipe()
        let buffer = ProcessToolOutputBuffer(maxBytes: 32)
        let handlerEntered = DispatchSemaphore(value: 0)
        let allowAppend = DispatchSemaphore(value: 0)
        let reader = ProcessToolPipeReader(handle: pipe.fileHandleForReading, buffer: buffer) {
            handlerEntered.signal()
            _ = allowAppend.wait(timeout: .now() + 2)
        }
        reader.start()
        try pipe.fileHandleForWriting.write(contentsOf: Data("holoscape".utf8))
        XCTAssertEqual(handlerEntered.wait(timeout: .now() + 2), .success)

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = reader.finish()
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 0.05), .timedOut)
        allowAppend.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        try pipe.fileHandleForWriting.close()

        XCTAssertEqual(buffer.snapshot().string, "holoscape")
    }

    func testMissingStatusReportsUnknownExecutionWithoutClaimingLaunchFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sideEffect = directory.appendingPathComponent("side-effect")
        do {
            _ = try await runProcessTool(
                request(
                    command: "printf completed > \(sideEffect.path)",
                    environment: ["HOLOSCAPE_PROCESS_TOOL_TEST_STATUS_WRITE_FAILURE": "1"]
                ),
                launcherExecutableURL: launcherExecutableURL
            )
            XCTFail("Missing status must not be reported as success")
        } catch let error as ProcessToolError {
            guard case .executionStatusUnavailable = error else {
                return XCTFail("Expected unknown execution status, got \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("may have run"))
            XCTAssertFalse(error.localizedDescription.contains("Failed to launch"))
        }

        XCTAssertEqual(try String(contentsOf: sideEffect, encoding: .utf8), "completed")
    }

    func testUnacknowledgedPublishedStatusCannotBecomeSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-unacknowledged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let launcher = directory.appendingPathComponent("unacknowledged-controller")
        try Data("#!/bin/zsh\nprint -n 'completed:0' > \"$4\"\nexit 123\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)

        do {
            _ = try await runProcessTool(
                request(command: "exit 0"),
                launcherExecutableURL: launcher,
                temporaryDirectoryURL: directory
            )
            XCTFail("An unacknowledged status must not become a successful result")
        } catch let error as ProcessToolError {
            guard case .executionStatusUnavailable(let reason) = error else {
                return XCTFail("Expected unavailable execution status, got \(error)")
            }
            XCTAssertTrue(reason.contains("acknowledgement"), "Unexpected reason: \(reason)")
        }
    }

    func testAcknowledgementTimeoutWithoutObservedStatusIsExplicit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-missed-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let launcher = directory.appendingPathComponent("missed-status-controller")
        try Data("#!/bin/zsh\nexit 123\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)

        do {
            _ = try await runProcessTool(request(command: "exit 0"), launcherExecutableURL: launcher)
            XCTFail("An acknowledgement timeout must not become a generic missing status")
        } catch let error as ProcessToolError {
            guard case .executionStatusUnavailable(let reason) = error else {
                return XCTFail("Expected unavailable execution status, got \(error)")
            }
            XCTAssertTrue(reason.contains("acknowledgement"), "Unexpected reason: \(reason)")
        }
    }

    func testCleanupFailureExitCannotConfirmSuccessfulCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-false-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let launcher = directory.appendingPathComponent("false-cleanup-controller")
        try Data("#!/bin/zsh\nprint -n 'cancelled:groupSignaled' > \"$4\"\nexit 125\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)

        do {
            _ = try await runProcessTool(
                request(command: "exit 0"),
                launcherExecutableURL: launcher,
                temporaryDirectoryURL: directory
            )
            XCTFail("Exit 125 must not confirm successful cancellation cleanup")
        } catch let error as ProcessToolError {
            guard case .executionStatusUnavailable = error else {
                return XCTFail("Expected unavailable execution status, got \(error)")
            }
        } catch {
            XCTFail("Cleanup failure must not become CancellationError, got \(error)")
        }
    }

    func testStatusReadFailureIsNotSwallowed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-unreadable-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let launcher = directory.appendingPathComponent("unreadable-status-controller")
        try Data("#!/bin/zsh\nmkdir \"$4\"\nsleep 0.1\nexit 0\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)

        do {
            _ = try await runProcessTool(
                request(command: "exit 0"),
                launcherExecutableURL: launcher,
                temporaryDirectoryURL: directory
            )
            XCTFail("A status read failure must remain observable")
        } catch let error as ProcessToolError {
            guard case .executionStatusUnavailable(let reason) = error else {
                return XCTFail("Expected unavailable execution status, got \(error)")
            }
            XCTAssertTrue(reason.contains("Could not read controller status"), "Unexpected reason: \(reason)")
        }
    }

    func testCancellationDoesNotMaskLauncherFailure() async throws {
        let missingLauncher = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-holoscape-launcher-\(UUID().uuidString)")
        let processRequest = request(command: "exit 0")
        let task = Task {
            try await runProcessTool(
                processRequest,
                launcherExecutableURL: missingLauncher
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A launcher failure must remain a launch failure")
        } catch let error as ProcessToolError {
            guard case .launchFailed = error else {
                return XCTFail("Expected launch failure, got \(error)")
            }
        } catch {
            XCTFail("Cancellation must not mask launch failure, got \(error)")
        }
    }

    func testCompletedCleanupSignalFailurePropagatesAsMCPError() async throws {
        let result = try await runProcessTool(
            request(
                command: "printf completed",
                environment: ["HOLOSCAPE_PROCESS_TOOL_TEST_SIGNAL_FAILURE": "1"]
            ),
            launcherExecutableURL: launcherExecutableURL
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.processGroupCleanupSucceeded, false)
        XCTAssertTrue(formatProcessToolResult(result).contains("processGroupCleanupSucceeded: false"))
        XCTAssertTrue(processToolResultIsError(result))
    }

    func testTimeoutEnumerationFailureFailsClosedThroughMCPErrorContract() async throws {
        let result = try await runProcessTool(
            request(
                command: "while true; do sleep 1; done",
                environment: ["HOLOSCAPE_PROCESS_TOOL_TEST_ENUMERATION_FAILURE": "1"],
                timeoutSeconds: 0.1
            ),
            launcherExecutableURL: launcherExecutableURL
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.processGroupCleanupSucceeded, false)
        XCTAssertTrue(formatProcessToolResult(result).contains("processGroupCleanupSucceeded: false"))
        XCTAssertTrue(processToolResultIsError(result))
    }

    func testShellRunnerInfrastructureFailureIsNotCommandExit127() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-runner-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sideEffect = directory.appendingPathComponent("should-not-exist")

        do {
            _ = try await runProcessTool(
                request(
                    command: "touch \(sideEffect.path); exit 127",
                    environment: ["HOLOSCAPE_PROCESS_TOOL_TEST_RUNNER_FAILURE": "1"]
                ),
                launcherExecutableURL: launcherExecutableURL
            )
            XCTFail("Runner infrastructure failure must throw")
        } catch let error as ProcessToolError {
            guard case .launchFailed(let reason) = error else {
                return XCTFail("Expected launch failure, got \(error)")
            }
            XCTAssertTrue(reason.contains("Injected shell-runner launch failure"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: sideEffect.path))
    }

    func testRunProcessToolPreservesOutputBelowLimit() async throws {
        let result = try await runProcessTool(
            request(command: "printf holoscape; printf warning >&2"),
            maxOutputBytes: 32,
            launcherExecutableURL: launcherExecutableURL
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.stdout, "holoscape")
        XCTAssertEqual(result.stderr, "warning")
        XCTAssertFalse(result.stdoutTruncated)
        XCTAssertFalse(result.stderrTruncated)
        XCTAssertNil(result.processGroupCleanupSucceeded)
        XCTAssertFalse(formatProcessToolResult(result).contains("Truncated"))
    }

    func testRunProcessToolCapsStdoutAndReportsTruncation() async throws {
        let result = try await runProcessTool(
            request(command: "printf 123456789"),
            maxOutputBytes: 5,
            launcherExecutableURL: launcherExecutableURL
        )

        XCTAssertEqual(result.stdout, "12345")
        XCTAssertTrue(result.stdoutTruncated)
        XCTAssertFalse(result.stderrTruncated)
        XCTAssertTrue(formatProcessToolResult(result).contains("stdoutTruncated: true"))
    }

    func testRunProcessToolCapsStderrAndReportsTruncation() async throws {
        let result = try await runProcessTool(
            request(command: "printf abcdefghi >&2"),
            maxOutputBytes: 5,
            launcherExecutableURL: launcherExecutableURL
        )

        XCTAssertEqual(result.stderr, "abcde")
        XCTAssertFalse(result.stdoutTruncated)
        XCTAssertTrue(result.stderrTruncated)
        XCTAssertTrue(formatProcessToolResult(result).contains("stderrTruncated: true"))
    }

    func testRunProcessToolPreservesNonzeroExit() async throws {
        let result = try await runProcessTool(
            request(command: "exit 17"),
            launcherExecutableURL: launcherExecutableURL
        )

        XCTAssertEqual(result.exitCode, 17)
        XCTAssertFalse(result.timedOut)
    }

    func testRunProcessToolLaunchesDedicatedProcessGroup() async throws {
        let callerProcessGroup = getpgrp()
        let result = try await runProcessTool(
            request(command: "test \"$(ps -o pgid= -p $$ | tr -d ' ')\" != \"\(callerProcessGroup)\""),
            launcherExecutableURL: launcherExecutableURL
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
    }

    func testCancellationSignalRetainsCloseFailureForCaller() throws {
        enum InjectedFailure: Error { case close }
        let pipe = Pipe()
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        let signal = ProcessToolCancellationSignal(
            writeHandle: pipe.fileHandleForWriting,
            writeOperation: { _ in },
            closeOperation: { _ in throw InjectedFailure.close }
        )

        signal.request()
        let outcome = signal.finish()

        XCTAssertTrue(outcome.wasRequested)
        XCTAssertTrue(outcome.signalingFailure?.contains("close failed") == true)
    }

    func testCallerDisappearanceCleansProcessTreeWithoutLeavingStatus() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-caller-loss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let parentPIDURL = directory.appendingPathComponent("parent.pid")
        let childPIDURL = directory.appendingPathComponent("child.pid")
        let statusURL = directory.appendingPathComponent("controller.status")
        let command = """
        zmodload zsh/zselect
        echo $$ > \(parentPIDURL.path)
        trap '' TERM
        /bin/zsh -c 'zmodload zsh/zselect; echo $$ > \(childPIDURL.path); trap "" TERM; while true; do zselect -t 100; done' &
        while true; do zselect -t 100; done
        """

        let controller = Process()
        let lifetimePipe = Pipe()
        controller.executableURL = launcherExecutableURL
        controller.arguments = ["--holoscape-process-controller", command, "2", statusURL.path]
        controller.standardInput = lifetimePipe
        controller.standardOutput = Pipe()
        controller.standardError = Pipe()
        try controller.run()
        try lifetimePipe.fileHandleForReading.close()
        try await waitForFiles([parentPIDURL, childPIDURL])
        let parentPID = try pid(from: parentPIDURL)
        let childPID = try pid(from: childPIDURL)
        defer {
            _ = Darwin.kill(parentPID, SIGKILL)
            _ = Darwin.kill(childPID, SIGKILL)
        }

        let startedAt = DispatchTime.now()
        try lifetimePipe.fileHandleForWriting.close()
        controller.waitUntilExit()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000_000

        XCTAssertLessThan(elapsed, 1.8, "Caller loss must not wait for the configured timeout")
        assertProcessIsGone(parentPID, "Caller loss must retire the shell")
        assertProcessIsGone(childPID, "Caller loss must retire descendants")
        XCTAssertFalse(FileManager.default.fileExists(atPath: statusURL.path))
    }

    func testCallerDisappearanceAfterStatusPublicationRemovesStatus() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-late-caller-loss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let statusURL = directory.appendingPathComponent("controller.status")
        let controller = Process()
        let lifetimePipe = Pipe()
        controller.executableURL = launcherExecutableURL
        controller.arguments = ["--holoscape-process-controller", "exit 0", "2", statusURL.path]
        controller.standardInput = lifetimePipe
        controller.standardOutput = Pipe()
        controller.standardError = Pipe()
        try controller.run()
        try lifetimePipe.fileHandleForReading.close()
        try await waitForFiles([statusURL])

        try lifetimePipe.fileHandleForWriting.close()
        controller.waitUntilExit()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: statusURL.path),
            "Caller loss after status publication must remove the unconsumed artifact"
        )
    }

    func testCancellingRunProcessToolTerminatesResistantProcessTreeBeforeReturning() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-cancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let parentPIDURL = directory.appendingPathComponent("parent.pid")
        let childPIDURL = directory.appendingPathComponent("child.pid")
        let statusDirectory = directory.appendingPathComponent("status")
        try FileManager.default.createDirectory(at: statusDirectory, withIntermediateDirectories: true)
        let command = """
        zmodload zsh/zselect
        echo $$ > \(parentPIDURL.path)
        trap '' TERM
        /bin/zsh -c 'zmodload zsh/zselect; echo $$ > \(childPIDURL.path); trap "" TERM; while true; do zselect -t 100; done' &
        while true; do zselect -t 100; done
        """

        let processRequest = request(command: command, timeoutSeconds: 2)
        let launcherURL = launcherExecutableURL
        let task = Task {
            try await runProcessTool(
                processRequest,
                maxOutputBytes: 32,
                launcherExecutableURL: launcherURL,
                temporaryDirectoryURL: statusDirectory
            )
        }
        try await waitForFiles([parentPIDURL, childPIDURL])
        let parentPID = try pid(from: parentPIDURL)
        let childPID = try pid(from: childPIDURL)
        defer {
            _ = Darwin.kill(parentPID, SIGKILL)
            _ = Darwin.kill(childPID, SIGKILL)
        }

        let startedAt = DispatchTime.now()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must not return a normal process result")
        } catch {
            XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000_000

        XCTAssertLessThan(elapsed, 1.8, "Cancellation must not wait for the configured timeout")
        assertProcessIsGone(parentPID, "Cancelled shell must be gone before returning")
        assertProcessIsGone(childPID, "Cancelled descendants must be gone before returning")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: statusDirectory.path),
            [],
            "Cancellation must remove its controller status file"
        )
    }

    func testCancellationSignalFailureIsSurfacedAfterProcessCleanup() async throws {
        enum InjectedFailure: Error { case close }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-signal-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let shellPIDURL = directory.appendingPathComponent("shell.pid")
        let processRequest = request(
            command: "echo $$ > \(shellPIDURL.path); while true; do sleep 1; done",
            timeoutSeconds: 2
        )
        let launcherURL = launcherExecutableURL
        let task = Task {
            try await runProcessTool(
                processRequest,
                launcherExecutableURL: launcherURL,
                cancellationSignalFactory: { handle in
                    ProcessToolCancellationSignal(
                        writeHandle: handle,
                        closeOperation: { _ in throw InjectedFailure.close }
                    )
                }
            )
        }
        try await waitForFiles([shellPIDURL])
        let shellPID = try pid(from: shellPIDURL)
        defer { _ = Darwin.kill(shellPID, SIGKILL) }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Signal failure must not report successful cancellation")
        } catch let error as ProcessToolError {
            guard case .cancellationSignalFailed = error else {
                return XCTFail("Expected cancellation signal failure, got \(error)")
            }
        } catch {
            XCTFail("Expected explicit cancellation signal failure, got \(error)")
        }

        assertProcessIsGone(shellPID, "Signal close failure must not skip delivered process cleanup")
    }

    func testCancellationStatusRemovalFailureIsSurfaced() async throws {
        enum InjectedFailure: Error { case removal }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-status-removal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let shellPIDURL = directory.appendingPathComponent("shell.pid")
        let processRequest = request(
            command: "echo $$ > \(shellPIDURL.path); while true; do sleep 1; done",
            timeoutSeconds: 2
        )
        let launcherURL = launcherExecutableURL
        let task = Task {
            try await runProcessTool(
                processRequest,
                launcherExecutableURL: launcherURL,
                temporaryDirectoryURL: directory,
                statusRemover: { _ in throw InjectedFailure.removal }
            )
        }
        try await waitForFiles([shellPIDURL])
        let shellPID = try pid(from: shellPIDURL)
        defer { _ = Darwin.kill(shellPID, SIGKILL) }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Status removal failure must not report successful cancellation")
        } catch let error as ProcessToolError {
            guard case .statusCleanupFailed = error else {
                return XCTFail("Expected status cleanup failure, got \(error)")
            }
        } catch {
            XCTFail("Expected explicit status cleanup failure, got \(error)")
        }

        assertProcessIsGone(shellPID, "Status cleanup failure must not skip process cleanup")
        let residue = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".status") }
        XCTAssertEqual(residue.count, 1, "Injected removal failure must exercise a real status artifact")
    }

    func testCancellationRaceWithImmediateCompletionResolvesOnce() async throws {
        let launcherURL = launcherExecutableURL
        for _ in 0..<10 {
            let processRequest = request(command: "exit 0")
            let task = Task {
                try await runProcessTool(processRequest, launcherExecutableURL: launcherURL)
            }
            task.cancel()

            do {
                let result = try await task.value
                XCTAssertEqual(result.exitCode, 0)
            } catch {
                XCTAssertTrue(error is CancellationError, "Expected completion or CancellationError, got \(error)")
            }
        }
    }

    func testCancellationCleanupFailureIsSurfacedInsteadOfClaimingCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-cancellation-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let shellPIDURL = directory.appendingPathComponent("shell.pid")
        let processRequest = request(
            command: "echo $$ > \(shellPIDURL.path); while true; do sleep 1; done",
            environment: ["HOLOSCAPE_PROCESS_TOOL_TEST_SIGNAL_FAILURE": "1"],
            timeoutSeconds: 2
        )
        let launcherURL = launcherExecutableURL
        let task = Task {
            try await runProcessTool(processRequest, launcherExecutableURL: launcherURL)
        }
        try await waitForFiles([shellPIDURL])
        let shellPID = try pid(from: shellPIDURL)
        defer { _ = Darwin.kill(shellPID, SIGKILL) }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Unproven cleanup must not return a normal result")
        } catch let error as ProcessToolError {
            guard case .cancellationCleanupFailed = error else {
                return XCTFail("Expected cancellation cleanup failure, got \(error)")
            }
        } catch {
            XCTFail("Expected explicit cleanup failure, got \(error)")
        }

        assertProcessExists(shellPID, "Injected cleanup failure must not be reported as successful cancellation")
    }

    func testRunProcessToolTimeoutTerminatesResistantProcessTreeBeforeReturning() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let parentPIDURL = directory.appendingPathComponent("parent.pid")
        let childPIDURL = directory.appendingPathComponent("child.pid")
        let command = """
        zmodload zsh/zselect
        echo $$ > \(parentPIDURL.path)
        trap '' TERM
        /bin/zsh -c 'zmodload zsh/zselect; echo $$ > \(childPIDURL.path); trap "" TERM; while true; do zselect -t 100; done' &
        while true; do zselect -t 100; done
        """

        let result = try await runProcessTool(
            request(command: command, timeoutSeconds: 0.5),
            maxOutputBytes: 32,
            launcherExecutableURL: launcherExecutableURL
        )

        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.processGroupCleanupSucceeded, true)
        let parentPID = try pid(from: parentPIDURL)
        let childPID = try pid(from: childPIDURL)
        defer {
            _ = Darwin.kill(parentPID, SIGKILL)
            _ = Darwin.kill(childPID, SIGKILL)
        }
        assertProcessIsGone(parentPID, "Timed-out shell must be gone before returning")
        assertProcessIsGone(childPID, "Timed-out descendants must be gone before returning")
    }

    func testNormalCompletionCleansDescendantsAfterRootExits() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-root-exit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let childPIDURL = directory.appendingPathComponent("child.pid")
        let command = """
        /bin/zsh -c 'zmodload zsh/zselect; echo $$ > \(childPIDURL.path); trap "" TERM; while true; do zselect -t 100; done' &
        while [[ ! -f \(childPIDURL.path) ]]; do sleep 0.01; done
        exit 0
        """

        let result = try await runProcessTool(
            request(command: command),
            launcherExecutableURL: launcherExecutableURL
        )

        let childPID = try pid(from: childPIDURL)
        defer { _ = Darwin.kill(childPID, SIGKILL) }
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, 0)
        assertProcessIsGone(childPID, "Normal completion must not leave descendants after the root exits")
    }

    func testImmediateCommandsDoNotRaceControllerSetup() async throws {
        for _ in 0..<20 {
            let result = try await runProcessTool(
                request(command: "exit 0"),
                launcherExecutableURL: launcherExecutableURL
            )
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertFalse(result.timedOut)
        }
    }

    func testKillingDirectParentCannotDisableGroupCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-parent-kill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let shellPIDURL = directory.appendingPathComponent("shell.pid")
        let command = """
        zmodload zsh/zselect
        echo $$ > \(shellPIDURL.path)
        kill -KILL $PPID
        trap '' TERM
        while true; do zselect -t 100; done
        """

        let result = try await runProcessTool(
            request(command: command, timeoutSeconds: 1),
            launcherExecutableURL: launcherExecutableURL
        )

        let shellPID = try pid(from: shellPIDURL)
        defer { _ = Darwin.kill(shellPID, SIGKILL) }
        XCTAssertEqual(result.exitCode, SIGKILL)
        XCTAssertFalse(result.timedOut)
        assertProcessIsGone(shellPID, "Killing $PPID must not strand the command group")
    }

    func testStoppingDirectParentCannotDisableTimeout() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-parent-stop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let shellPIDURL = directory.appendingPathComponent("shell.pid")
        let command = """
        zmodload zsh/zselect
        echo $$ > \(shellPIDURL.path)
        kill -STOP $PPID
        trap '' TERM
        while true; do zselect -t 100; done
        """

        let result = try await runProcessTool(
            request(command: command, timeoutSeconds: 0.5),
            launcherExecutableURL: launcherExecutableURL
        )

        let shellPID = try pid(from: shellPIDURL)
        defer { _ = Darwin.kill(shellPID, SIGKILL) }
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.processGroupCleanupSucceeded, true)
        assertProcessIsGone(shellPID, "Stopping $PPID must not disable timeout cleanup")
    }

    func testDetachedDescendantIsOutsideProcessGroupCleanupContract() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("holoscape-process-tool-detached-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let detachedPIDURL = directory.appendingPathComponent("detached.pid")
        let python = "import os,time; os.setsid(); f=open('\(detachedPIDURL.path)','w'); f.write(str(os.getpid())); f.close(); [os.close(fd) for fd in (0,1,2)]; time.sleep(30)"
        let command = """
        /usr/bin/python3 -c \(shellQuote(python)) &
        while [[ ! -f \(detachedPIDURL.path) ]]; do sleep 0.01; done
        while true; do sleep 1; done
        """

        let startedAt = DispatchTime.now()
        let result = try await runProcessTool(
            request(command: command, timeoutSeconds: 0.5),
            launcherExecutableURL: launcherExecutableURL
        )
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000_000

        let detachedPID = try pid(from: detachedPIDURL)
        defer { _ = Darwin.kill(detachedPID, SIGKILL) }
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.processGroupCleanupSucceeded, true)
        XCTAssertLessThan(elapsed, 3, "A detached process must not block group cleanup")
        assertProcessExists(detachedPID, "A process that deliberately leaves the group is outside the cleanup contract")
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func request(
        command: String,
        environment: [String: String] = [:],
        timeoutSeconds: Double = 2
    ) -> ProcessToolRequest {
        ProcessToolRequest(
            command: command,
            workingDirectory: nil,
            environment: environment,
            timeoutSeconds: timeoutSeconds
        )
    }

    private func waitForFiles(_ urls: [URL]) async throws {
        for _ in 0..<200 {
            if urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for process PID files")
        throw NSError(domain: "ProcessToolTests", code: 1)
    }

    private func pid(from url: URL) throws -> pid_t {
        let value = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(pid_t(value))
    }

    private func assertProcessIsGone(_ pid: pid_t, _ message: String) {
        errno = 0
        let result = Darwin.kill(pid, 0)
        let error = errno
        XCTAssertEqual(result, -1, message)
        XCTAssertEqual(error, ESRCH, message)
    }

    private func assertProcessExists(_ pid: pid_t, _ message: String) {
        XCTAssertEqual(Darwin.kill(pid, 0), 0, message)
    }
}
